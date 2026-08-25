# K3 Midnight Adapter — Architecture and Stacked Implementation Plan

> **For coding agents:** Implement this document in order. Each numbered implementation stage is one branch and one pull request in a single `gh stack` stack. Do not collapse stages, reorder branches, or add production behavior not described here without approval from the Engineering squad lead.

**Status:** Approved design baseline for implementation planning  
**Repository:** `https://github.com/K3-Capital/k3-midnight-adapter`  
**Parent task:** KOP-185  
**Primary language/tooling:** Solidity, Foundry, `gh stack` official extension  
**Target product:** Permissionless Morpho Vault V2 USDC vault allocating to one multi-market Midnight adapter, with Morpho Blue as the productive liquid sleeve and best-effort synchronous withdrawals.

---

## 1. Executive summary

Build two primary contracts:

1. **`PolicySetterRatifier`** — approves Merkle roots for a contract maker while checking every decoded Midnight offer against the maker adapter's current policy.
2. **`BlueMidnightAdapter`** — a Morpho Vault V2 adapter that is also the Midnight maker, lender-credit owner, buy callback, and sell callback. It supplies uncommitted USDC to one curator-approved Morpho Blue market, atomically withdraws Blue liquidity for Midnight buys, returns sell/repayment proceeds to Blue, reports conservative NAV, and supports best-effort deallocation.

The vault, adapter, and Midnight credit—not the curator or quoter—own depositor assets. The quoter may approve and revoke short-lived offer roots but cannot withdraw funds, change policy, grant protocol authorizations, select arbitrary callbacks, or redirect sale proceeds.

The implementation must preserve this invariant:

> Allocated USDC can only remain in the approved Morpho Blue supply position, become policy-valid Midnight lender credit owned by the adapter, or return to the parent vault. Every Midnight sell pays the adapter, and no quoter-controlled address can receive pooled value.

## 2. Goals

- Permissionless USDC deposits through Morpho Vault V2.
- One adapter instance supports multiple explicitly enabled Midnight markets.
- One active Morpho Blue idle-liquidity market per adapter in v1.
- Idle strategy capital earns Morpho Blue supply yield while Midnight offers wait.
- Curator-configurable market, rate, maturity, root lifetime, root notional, exposure, and exit-price limits.
- Quoter-controlled buy and sell roots, constrained by live onchain policy.
- Best-effort synchronous Vault V2 withdrawals from raw USDC, Morpho Blue liquidity, repayments, or safe credit sales.
- Track the adapter-owned Blue shares if needed for donation-safe accounting.
- Immediate recognition of Midnight losses and realized sale P&L.
- Constant-time market accounting and explicit gas/liveness limits.
- Emergency quoter revocation and epoch-wide root invalidation.
- Stacked, independently reviewable PRs with unit, fuzz, invariant, integration, and fork tests.

## 3. Non-goals

- Guaranteed redemption of 100% of TVL during a liquidity run.
- Async/ERC-7540 withdrawal queues in v1.
- Multiple active Morpho Blue idle markets per adapter.
- Arbitrary curator token rescue of USDC, Blue supply shares, or Midnight credit.
- Generic external calls from the adapter.
- Quoter access to Vault V2 allocator/curator/sentinel roles.
- Quoter authorization in Midnight or Morpho Blue.
- Upgradeable proxy contracts in v1.
- RateDesk application changes inside this repository. This repository may expose ABI artifacts and operator helpers; `k3-ratedesk` integration is a later, separate repository change after contract interfaces stabilize.
- Mainnet deployment before independent security review.

## 4. Verified source baseline

Implementation must pin and inspect these upstream revisions rather than coding against moving `main` branches:

1. Midnight `709dab354d8f03e64effc2a3dcdd08f5013a0758`, especially `Midnight.sol`, `IMidnight.sol`, `SetterRatifier.sol`, callback interfaces, hashing libraries, and `BlueBuyCallback.sol` (pinned source links are in §25).
2. Morpho Vault V2 `bec4dd8c847525efea95e106b38a70eaabeef65f`, especially `IAdapter.sol`, `IVaultV2.sol`, `VaultV2.sol`, and `MorphoMarketV1AdapterV2.sol` (pinned source links are in §25).
3. Morpho Blue at the exact revision referenced by the pinned Midnight/Vault V2 dependencies. Do not introduce a second incompatible copy.
4. `gh stack` official extension; installation and command semantics are documented by GitHub (see §25).

Use Solidity `0.8.34` with a deployable EVM target agreed during Stage 1; import interface-only upstream files where possible. Stage 1 must prove the combined dependency graph compiles before later contracts are implemented.

## 5. System context

```text
Permissionless USDC depositors (K3 and external users)
                         │
                         ▼
                  Morpho Vault V2
                         │ allocate/deallocate
                         ▼
                BlueMidnightAdapter
             ┌───────────┴───────────┐
             │                       │
     Morpho Blue supply        Midnight lender credit
     productive liquid sleeve  term/illiquid sleeve
             │                       │
             └───────────┬───────────┘
                         │ realAssets()
                         ▼
                  Morpho Vault V2

K3 quoter ── approveRoot/revokeRoot ──▶ adapter ──▶ PolicySetterRatifier
Curator ── timelocked policy ─────────▶ adapter
Sentinel ── revoke pending/risk-off ──▶ adapter
Keeper ── collect repayments ─────────▶ adapter
```

Vault V2 invokes `allocate(bytes,uint256,bytes4,address)`, `deallocate(bytes,uint256,bytes4,address)`, and `realAssets()` on adapters. Midnight calls buy callbacks before pulling buyer assets and sell callbacks after transferring seller proceeds. See the pinned interfaces and implementations in §25.

## 6. Roles and trust boundaries

### 6.1 Parent Vault V2

- Immutable `parentVault` on the adapter.
- Sole caller of `allocate` and `deallocate`.
- Owns the economic claim on every adapter asset.
- Uses the parent Vault adapter cap as the sole concentration boundary.[5]

### 6.2 Vault owner

- Selects Vault V2 curator and sentinels through Vault V2 governance.
- Does not receive an adapter withdrawal or rescue function.

### 6.3 Curator

Resolve dynamically through `IVaultV2(parentVault).curator()`.

May:

- submit timelocked policy expansions;
- activate executable policy changes;
- configure the pinned market's economics and offer limits;
- configure the single Morpho Blue idle market;
- appoint and revoke quoter addresses;


Must not:

- transfer primary assets to itself;
- bypass timelocks for risk expansion;
- choose an arbitrary sell receiver;
- authorize arbitrary Morpho Blue or Midnight callers.

### 6.4 Sentinel

Resolve through the parent Vault V2 sentinel getter.

May immediately:

- revoke pending policy changes;
- disable a Midnight market;
- lower exposure/root caps;
- tighten rate, price, maturity, or expiry limits;
- revoke a quoter;
- increment the policy epoch.

Sentinel must not expand risk or withdraw assets.

### 6.5 Quoter

May only call narrow adapter root-management functions for the current epoch.

Must not be authorized directly by Midnight or Morpho Blue. Midnight authorization would also permit position withdrawal and further delegation; SetterRatifier's existing broad authorization model therefore must not be exposed directly to the quoter.

### 6.6 Permissionless keeper/caller

May:

- collect available Midnight repayments to the adapter;
- resupply collected USDC to Blue;
- call safe maintenance/checkpoint functions;
- call functions such as `skim` only when the destination is fixed to the adapter/parent vault.

No permissionless function may select a receiver.

## 7. Contract inventory

```text
src/
├── PolicySetterRatifier.sol
├── BlueMidnightAdapter.sol
├── BlueMidnightAdapterFactory.sol
├── interfaces/
│   ├── IBlueMidnightAdapter.sol
│   ├── IOfferPolicy.sol
│   └── IPolicySetterRatifier.sol
├── libraries/
│   ├── AccountingLib.sol
│   ├── OfferPolicyLib.sol
│   └── RiskIdLib.sol
└── types/
    └── AdapterTypes.sol

test/
├── unit/
│   ├── PolicySetterRatifier.t.sol
│   ├── BlueMidnightAdapterAllocation.t.sol
│   ├── BlueMidnightAdapterCallbacks.t.sol
│   ├── BlueMidnightAdapterAccounting.t.sol
│   ├── BlueMidnightAdapterExit.t.sol
│   └── BlueMidnightAdapterTimelock.t.sol
├── fuzz/
│   ├── AccountingFuzz.t.sol
│   └── OfferPolicyFuzz.t.sol
├── invariant/
│   └── SolvencyInvariant.t.sol
├── integration/
│   └── VaultBlueMidnightIntegration.t.sol
└── fork/
    └── BaseFork.t.sol

script/
├── DeployFactory.s.sol
└── DeployPilot.s.sol

docs/
├── design.md
├── operations.md
└── threat-model.md
```

A coding agent may refine names during Stage 1, but moving responsibilities between contracts requires lead approval.

## 8. `PolicySetterRatifier`

### 8.1 Responsibility

Verify that:

1. the caller is the immutable Midnight instance;
2. `ratifierData` decodes to `(root, leafIndex, proof)`;
3. the leaf is the hash of the exact decoded offer;
4. the root was approved by the offer maker for the maker's current policy epoch;
5. the maker is a contract implementing `IOfferPolicy`;
6. the maker adapter accepts the exact offer under its live policy.

The existing SetterRatifier checks Merkle membership and a maker/root boolean but does not check the caller or offer economics. Implement a separate contract rather than changing upstream source in place.

### 8.2 Root state

Recommended shape:

```solidity
mapping(address maker => mapping(bytes32 root => uint64 epoch)) public approvedAtEpoch;
```

`setRoot(address maker, bytes32 root, bool approved)` must accept calls only from the maker itself. The quoter calls `BlueMidnightAdapter.setRoot`; the adapter checks its quoter role and relays the call as maker.

Do not use `IMidnight.isAuthorized(maker, caller)` for quoter permissions.

### 8.3 Epoch behavior

- Each adapter has `policyEpoch()` starting at a non-zero value.
- Ratification requires `approvedAtEpoch[maker][root] == adapter.policyEpoch()`.
- Disabling a root writes zero.
- Any accepted policy change increments the epoch.
- Emergency risk-off increments the epoch immediately.
- Overflow must be impossible in practical operation and tested explicitly.

### 8.4 Failure behavior

Revert with specific custom errors for wrong caller, malformed proof data, invalid proof, inactive root, invalid maker-policy provider, and rejected offer policy.

Return Midnight's expected callback success constant only after all checks pass.

## 9. `BlueMidnightAdapter`

### 9.1 Immutables

- `factory`
- `parentVault`
- `asset` from `parentVault.asset()`
- `midnight`
- `morphoBlue`
- `ratifier`
- adapter-wide `adapterId`

The asset must match the Morpho Blue market loan token and every enabled Midnight market loan token.

### 9.2 Vault V2 adapter interface

Implement the exact pinned `IAdapter` signatures.

#### `allocate`

- Require `msg.sender == parentVault`.
- Reject non-empty/unrecognized data in v1 unless the design explicitly defines it.
- Supply exactly `assets` to the configured Morpho Blue market on behalf of the adapter.
- Track the adapter-owned Blue shares if needed for donation-safe accounting.
- Return deterministic adapter/risk IDs and the true change in adapter allocation.
- Use balance/share deltas; do not assume exact share conversion.

#### `deallocate`

- Require `msg.sender == parentVault`.
- Attempt exact withdrawal from the configured Morpho Blue position.
- Transfer/approve exactly the requested assets back to the parent vault according to the pinned Vault V2 adapter convention.
- Revert when Blue supply or market liquidity is insufficient.
- Do not silently return less than requested.
- A later Stage 5 path may decode an explicitly versioned safe-exit payload before the Blue withdrawal.

#### `realAssets`

Return:

```text
adapter USDC balance
+ expected Morpho Blue supply assets owned by adapter
+ conservative book value for the one immutable pinned Midnight market
```

The method must be view-only and explicit about upstream reverts. There is no active-market loop: the adapter is immutable to one exact Midnight market. Vault V2 relies on `realAssets()` during interest accrual; an unbounded or reverting implementation can block vault operations.

### 9.3 Risk IDs

Return at minimum:

- adapter instance ID;
- Morpho Blue idle-market ID;
- Midnight protocol/strategy ID;
- exact pinned Midnight market risk ID derived from its EIP-712 market hash.

The parent Vault adapter cap is the sole concentration boundary. The adapter must return the exact pinned-market risk ID so Vault V2 can attribute the configured sleeve without any internal per-market cap.

## 10. Morpho Blue idle-liquidity sleeve

### 10.1 Configuration

Support one active Blue `MarketParams` in v1.

- Store the exact market parameters or immutable ID plus reconstructable parameters.
- Require `loanToken == asset`.
- Configuration/expansion is timelocked.
- Migration requires old supply to reach zero before activating a new market.
- Callback data cannot choose a Blue market.

The stock Blue callback decodes quoter-provided `MarketParams` and checks only loan-token consistency; this is insufficient for the pooled adapter.

### 10.2 Availability bound

Expose `buyerAssetsBound(pinnedMidnightMarketHash)` or equivalent returning the minimum of:

- adapter's expected Blue supply assets;
- current Blue market liquidity;
- actual loan-token balance held by Morpho Blue;
- the parent Vault allocation to this adapter.

The upstream Blue callback computes the first three quantities and deliberately treats routing information as potentially stale.

### 10.3 Authorization

Because the adapter supplies on behalf of itself, no quoter Blue authorization is necessary. Do not expose generic `setAuthorization`, `borrow`, arbitrary `call`, or arbitrary receiver methods.

## 11. Offer policy

### 11.1 Shared invariants

For every offer:

- `msg.sender` to the ratifier is the configured Midnight instance;
- `offer.maker == address(adapter)`;
- `offer.ratifier == address(PolicySetterRatifier)`;
- `offer.market.midnight == midnight`;
- `offer.market.chainId == block.chainid`;
- `offer.market.loanToken == asset`;
- exact Midnight market ID is enabled;
- offer start/expiry are valid and expiry horizon is within policy;
- offer group follows the adapter's epoch/root namespace;
- continuous fee cap and current settlement/continuous fees are bounded;
- root notional is non-zero and within policy.

Prefer tick bounds or a small audited rate-policy library over ad hoc APR conversion. Tests must prove the inequality direction for maker buys and maker sells against Midnight's `TickLib`.

### 11.2 Maker-buy offers

Require:

- `buy == true`;
- callback equals adapter;
- callback data is empty/versioned;
- seller-only receiver field is zero;
- offer cannot consume more than allowed notional;
- rate/price is at least as favorable as curator policy;
- maturity/tenor is allowed;
- dynamic exposure check passes again inside `onBuy` using actual fill arguments.

### 11.3 Maker-sell offers

Require:

- `buy == false`;
- callback equals adapter;
- `receiverIfMakerIsSeller == adapter`;
- `reduceOnly == true`;
- minimum sale price / maximum exit yield passes;
- sale size is bounded;
- adapter owns enough lender credit;
- actual `onSell` arguments match the expected seller and receiver.

Midnight transfers maker-sell proceeds to `receiverIfMakerIsSeller` before invoking `onSell`; both fields must therefore be pinned.

## 12. Callback flows

### 12.1 `onBuy`

Midnight calls the buy callback after position accounting but before pulling buyer assets.

Required sequence:

1. Require caller is Midnight.
2. Require buyer is adapter.
3. Derive and verify enabled Midnight market ID.
4. Checkpoint market accounting to current timestamp/loss factor.
5. Check actual fill against global and per-market capacity.
6. Withdraw exact `buyerAssets` from the configured Blue market to adapter.
7. Add purchase cost and net maturity claim to accounting.
8. Approve Midnight for exactly `buyerAssets` using safe allowance handling.
9. Emit fill/accounting event.
10. Return expected success constant.

Any failure reverts the whole Midnight fill, including its preceding state writes.

### 12.2 `onSell`

Midnight transfers sell proceeds before invoking the seller callback.

Required sequence:

1. Require caller is Midnight.
2. Require seller and receiver are adapter.
3. Verify enabled market.
4. Checkpoint accounting.
5. Reduce net claim/exposure and book value proportionally to sold credit.
6. Record realized P&L against `sellerAssets`.
7. Supply received USDC into the configured Blue market.
8. Emit fill/accounting event.
9. Return expected success constant.

### 12.3 Repayment collection

Expose a permissionless function taking a bounded list or one exact market:

1. checkpoint accounting;
2. call `Midnight.withdraw` from the adapter to the adapter for available units;
3. reduce book value/claim consistently;
4. supply received USDC to Blue;
5. emit collection event.

The quoter must not receive Midnight authorization for this flow.

## 13. Accounting and valuation

### 13.1 Scalar market state

The adapter has one immutable Midnight market, so the accounting record is scalar
and is never selected by a caller-supplied market key:

```solidity
struct MarketAccounting {
    uint128 bookValue;
    uint128 netMaturityClaim;
    uint128 trackedCredit;
    uint40 lastCheckpoint;
    bool active;
}
```

Final widths must be proven against upstream bounds and fuzz tests.

### 13.2 Amortized cost

For one Midnight market, all claims share the market maturity. At checkpoint time:

```text
earned = (netMaturityClaim - bookValue)
         * elapsed
         / (maturity - previousCheckpoint)

bookValue += earned
lastCheckpoint = min(now, maturity)
```

Handle these cases explicitly:

- first fill;
- multiple fills at different times;
- fill at/after maturity rejection;
- zero remaining duration;
- full and partial sale;
- early repayment/withdrawal;
- realized gain/loss on sale;
- Midnight loss-factor reduction;
- remaining continuous fee;
- rounding direction;
- market reaching zero credit;
- reactivation after zero.

Never allow book value to exceed net maturity claim solely through accrual.

### 13.3 Loss handling

Use Midnight's updated position view to compare current credit and remaining pending fee with tracked net claim. Recognize negative changes immediately and proportionally reduce book value before reporting NAV.

Do not defer known losses behind Vault V2 `maxRate`; `maxRate` is an outer positive-growth bound, not a loss oracle.

### 13.4 Blue value

Use expected Morpho Blue balances and adapter-owned supply shares. Recognize Blue interest and Blue bad-debt/loss effects in current supply assets.

### 13.5 Single-market concentration boundary

- Store one exact Midnight market and both its protocol ID and EIP-712 hash.
- Return its deterministic risk ID alongside the adapter and Blue IDs.
- Do not recreate an adapter-local exposure cap; Vault V2's adapter allocation/cap is the sole concentration boundary.

## 14. Timelocks, policy epochs, and emergency controls

Model adapter timelocks after `MorphoMarketV1AdapterV2`: selector-specific timelocks, `submit(data)`, executable timestamps, `revoke(data)`, and abdication where appropriate.

### Timelocked risk expansions

- configure/change Blue market;
- increase root notional/lifetime;
- loosen rate or exit-price limits;
- extend tenor/maturity bounds;

- change ratifier, only if mutability is retained.

### Immediate risk reductions

- disable market;
- lower exposure/root limits;
- tighten rate/price/tenor/expiry limits;
- revoke quoter;
- revoke pending action;
- bump epoch and invalidate all roots.

Every accepted policy change increments the epoch. Pending actions bind exact calldata so parameter substitution is impossible.

## 15. Best-effort withdrawals and safe exits

### 15.1 Normal deallocation

- Parent vault requests exact assets.
- Adapter withdraws exact assets from Blue and returns them.
- If Blue lacks liquidity, revert.
- This is expected product behavior, not an accounting failure.

### 15.2 Optional safe exit payload

Stage 5 may add versioned `deallocate` data containing one or more third-party maker-buy Midnight offers and proofs.

The adapter acts as taker/seller and must independently validate:

- exact enabled market;
- receiver for taker-side sale is adapter;
- minimum price / maximum exit yield;
- maximum units and loss;
- no arbitrary callback/payer;
- sufficient owned credit;
- offer validity and ratification;
- proceeds received before returning assets to Vault V2.

If safe sales plus Blue liquidity cannot produce the exact requested assets, revert the complete deallocation.

### 15.3 No in-kind withdrawal

Midnight lender credit is internal position accounting rather than a transferable receipt token. Do not claim in-kind redemption support.

## 16. Security invariants

Fuzz/invariant tests must cover at least:

1. Primary USDC can leave adapter only for Midnight settlement, Morpho Blue supply, or parent-vault deallocation.
2. Every maker sell receiver is adapter.
3. Quoter cannot call Midnight withdrawal as adapter or authorize another account.
4. Quoter cannot change policy, Blue market, caps, timelocks, or receivers.
5. Sentinel cannot expand risk.
6. Curator cannot bypass timelock for expansion.
7. Inactive/old-epoch roots never ratify.
8. A policy change cannot make an old root newly valid.
9. Aggregate exposure never exceeds global or market cap after callback completion.
10. `realAssets` does not double count Blue-to-Midnight or Midnight-to-Blue transitions.
11. Book value is bounded by claim value except explicitly realized/held cash.
12. Known Midnight or Blue losses reduce NAV.
13. Deallocation returns exact assets or reverts.
14. Arbitrary callback data cannot select another Blue market.
15. Reentrancy cannot alter parent-vault accounting or bypass caps.
16. Token allowance is exact or safely reset and cannot be consumed by the quoter.
17. Active-market loops remain bounded.
18. Donations/reward tokens cannot be skimmed to curator/quoter.
19. Partial fills across multiple roots cannot exceed dynamic caps.
20. Malicious cheap sells fail the exit-price policy even with a correct receiver.

## 17. Observability

Emit events for:

- root approval/revocation with maker, root, epoch, quoter;
- epoch increment and reason;
- quoter changes;
- policy submission/acceptance/revocation;
- market enable/disable and cap changes;
- Blue market configuration/migration;
- allocation/deallocation;
- buy/sell fill accounting;
- repayment collection;
- realized gain/loss;
- Midnight/Blue loss recognition;
- active-market add/remove;
- emergency risk-off.

Expose view methods for RateDesk/operators:

- current epoch;
- quoter status;
- root status;
- decoded policy by Midnight market ID;
- global/per-market current exposure and remaining capacity;
- `buyerAssetsBound`;
- Blue supply assets and available liquidity;
- active markets and count;
- per-market book value, claim value, loss, and maturity;
- aggregate liquid versus term-locked assets.

## 18. Testing strategy

### Unit tests

- Access control and role separation.
- Merkle proof/root/epoch behavior.
- Every buy/sell policy field and inequality boundary.
- Timelock expansion versus immediate reduction.
- Blue allocation/deallocation and liquidity reverts.
- Callback caller/buyer/seller/receiver validation.
- Root lifetime and stale policy behavior.

### Accounting tests

- Exact first fill and maturity value.
- Multiple partial fills at different times.
- Full/partial sale at gain, par, and loss.
- Early/full/partial repayment collection.
- Continuous fee and loss-factor changes.
- Blue interest and Blue loss.
- No double counting across every transition.
- Rounding at USDC decimals and maximum upstream bounds.

### Fuzz/invariant tests

Use handler-based random sequences of allocate, quote-root approval, buy fill, time advance, repay, withdraw, sell, Blue interest/loss, deallocate, policy change, and epoch bump.

### Integration tests

Deploy real local instances of Vault V2, Morpho Blue, Midnight, ratifier, adapter, and factory. Prove deposit → Vault allocation → Blue supply → Midnight buy → repayment/sell → Blue resupply → Vault deallocation → user withdrawal.

### Fork tests

Use pinned public contracts/configuration only after addresses and chain are approved. Fork tests are supplemental and must not replace deterministic local integration tests.

### Required commands

```bash
forge fmt --check
forge build
forge test --summary
forge test --match-path 'test/unit/**' -vvv
forge test --match-path 'test/fuzz/**' -vvv
forge test --match-path 'test/invariant/**' -vvv
forge coverage --ir-minimum
```

Record exact pass/fail counts and any coverage/tool limitations in each PR.

## 19. Deployment and rollback

### Deployment

1. Deploy immutable `PolicySetterRatifier` for target Midnight.
2. Deploy and register `BlueMidnightAdapterFactory`.
3. Deploy adapter for one parent Vault V2 and approved Blue market.
4. Configure adapter selector timelocks before adding it to Vault V2.
5. Add adapter to registry and set very low absolute/relative caps.
6. Configure one or two exact short-maturity Midnight markets.
7. Appoint replaceable quoter.
8. Enable adapter as liquidity adapter only after deallocation tests.
9. Seed with K3 capital; permissionless deposits remain possible if vault gates are open.
10. Monitor Blue liquidity, outstanding roots, Midnight exposure, maturity ladder, NAV deltas, and withdrawal failures.

### Rollback/risk-off

1. Revoke quoter and increment epoch.
2. Disable all new Midnight buys.
3. Keep repayment collection enabled.
4. Permit only policy-valid exits returning to adapter.
5. Lower Vault V2 adapter cap to zero for new allocation.
6. Withdraw Blue liquidity as available.
7. Wait for or safely sell term credit.
8. Remove adapter only after tracked and actual positions reach zero.

No emergency action may transfer primary assets to curator/quoter.

## 20. Stacked PR workflow

Install the official extension in a writable data directory when the runtime home is read-only:

```bash
export XDG_DATA_HOME="${K3_AGENT_CACHE_DIR:-$PWD/.cache}/gh-xdg"
mkdir -p "$XDG_DATA_HOME"
gh extension install github/gh-stack || gh extension upgrade github/gh-stack
gh stack --version
```

The six stack branches, bottom to top, are:

```text
stack/01-foundation
stack/02-policy-ratifier
stack/03-blue-adapter-core
stack/04-callbacks-accounting
stack/05-exits-liquidity
stack/06-integration-release
```

Stage 1:

```bash
gh stack init --base main stack/01-foundation
# implement, test, commit
gh stack submit --auto --open
```

Each later stage starts from the approved predecessor:

```bash
gh stack checkout <previous-PR-number>
gh stack sync
gh stack add -Am "<conventional commit subject>" stack/0N-name
gh stack submit --auto --open
```

Before reporting delivery:

```bash
gh stack view
gh pr view <new-PR-number> --json number,url,state,baseRefName,headRefName,commits,statusCheckRollup
git ls-remote origin "refs/heads/stack/0N-name"
```

Do not merge an intermediate PR independently unless `gh stack` reports a safe stack merge/rebase plan and the lead explicitly authorizes it.

## 21. Multica review-gate workflow

All implementation sub-issues are assigned to the **Engineering** squad and initially parked in `backlog` except when the Scrum Master promotes the current stage.

For each stage:

1. Scrum Master moves exactly one stage to `todo`.
2. Engineering implements only that stage and opens the stacked PR.
3. Engineering leaves the issue `in_progress` and returns the PR URL, commit SHA, stack view, local test output, and residual risks.
4. Engineering squad lead reviews the actual diff and validation evidence.
5. If changes are required, the same task/branch remains active.
6. When the lead approves the PR, the lead or Scrum Master moves that sub-issue to `in_review`.
7. Only then does Scrum Master promote the next backlog stage to `todo`.
8. Later stages stack on approved but not necessarily merged predecessor PRs.
9. After Stage 6 approval, Scrum Master coordinates final stack merge and closes/reconciles all child issues.

Never start two implementation stages concurrently; they modify one ordered stack.

## 22. Implementation stages and acceptance criteria

### Stage 1 — Foundation and compatibility harness

**Branch:** `stack/01-foundation`

Deliver:

- Foundry repository scaffold.
- Pinned Midnight, Vault V2, and Morpho Blue dependencies without duplicate type conflicts.
- License and notices compatible with upstream GPL dependencies.
- Imported interfaces and compilation harness.
- Contract/test directory skeleton.
- Design document at `docs/design.md`.
- `gh stack` contributor workflow in `CONTRIBUTING.md`.
- Local mocks/deploy helpers proving all upstream contracts can compile together.

Acceptance:

- `forge fmt --check`, `forge build`, and a smoke test pass.
- Dependency commits are documented and reproducible.
- No production contract behavior beyond interfaces/skeletons.

### Stage 2 — Policy setter ratifier

**Branch:** `stack/02-policy-ratifier`

Deliver:

- `PolicySetterRatifier` and interfaces.
- Maker-only root relay semantics.
- Epoch-bound root approvals.
- Merkle proof and exact-offer hashing compatible with Midnight.
- Adapter `IOfferPolicy` hook.
- Custom errors/events and exhaustive unit/fuzz tests.

Acceptance:

- Wrong caller, maker, proof, root, epoch, and policy all revert.
- No Midnight-authorized quoter bypass exists.
- Hash compatibility is proven against pinned Midnight vectors/tests.

### Stage 3 — Adapter core and Blue liquidity

**Branch:** `stack/03-blue-adapter-core`

Deliver:

- `BlueMidnightAdapter` core and interfaces.
- Vault V2 allocate/deallocate/realAssets integration.
- One fixed/configured Morpho Blue idle market.
- Blue supply accounting and `buyerAssetsBound`.
- Selector timelock framework, curator/sentinel role resolution, quoter registry, policy epoch.
- Deterministic risk IDs and bounded active-market storage foundation.

Acceptance:

- Only parent vault allocates/deallocates.
- Assets are supplied to Blue and exact available assets return to vault.
- Insufficient Blue liquidity reverts.
- Quoter has no Blue/Midnight generic authorization.

### Stage 4 — Midnight callbacks, policy, and NAV

**Branch:** `stack/04-callbacks-accounting`

Deliver:

- Direction-specific offer policy.
- `onBuy` and `onSell` integrated with Blue.
- Callback fills bounded by parent Vault allocation and Blue liquidity.
- Scalar amortized-cost accounting.
- Midnight fee/loss synchronization.
- Root relay functions and policy-epoch invalidation.
- Unit, fuzz, and accounting transition tests.

Acceptance:

- Buys atomically move value Blue → Midnight without NAV double counting.
- Sells atomically move value Midnight → adapter → Blue.
- Receiver/callback/market/rate/maturity/size/expiry violations revert.
- Partial fills and multiple roots cannot exceed caps.

### Stage 5 — Repayments, safe exits, and best-effort liquidity

**Branch:** `stack/05-exits-liquidity`

Deliver:

- Permissionless repayment collection returning assets to Blue.
- Versioned safe taker-side exit payload for deallocation.
- Exit validation, price/loss bounds, exact receiver pinning.
- Exact-or-revert deallocation behavior.
- Emergency risk-off and recovery tests.

Acceptance:

- Normal withdrawals use Blue liquidity synchronously when available.
- Illiquid withdrawals revert cleanly without accounting drift.
- Safe exits cannot redirect proceeds or exceed allowed loss.
- Repayments remain collectable after buys/quoter are disabled.

### Stage 6 — Factory, full integration, deployment, and release readiness

**Branch:** `stack/06-integration-release`

Deliver:

- Adapter factory and deterministic deployment support.
- Full local Vault V2 + Blue + Midnight integration suite.
- Handler invariants and coverage report.
- Pilot deployment script/config template with no secrets.
- ABI artifacts/operator views needed by RateDesk.
- `docs/operations.md`, `docs/threat-model.md`, deployment/risk-off runbook.
- Independent Solidity review request and remediation of blocking findings.

Acceptance:

- End-to-end lifecycle passes locally.
- All security invariants have tests or explicit residual-risk rationale.
- No plaintext secrets/state/runtime artifacts are committed.
- Stack view and all PR links are returned for final lead review.
- Mainnet remains blocked pending independent audit and explicit deployment approval.

## 23. Overall definition of done

- Six approved stacked PRs in `K3-Capital/k3-midnight-adapter`.
- Every PR maps one-to-one to its Multica child task and branch.
- Full Foundry suite, fuzz/invariant suite, and local integration suite pass.
- Policy blocks malicious receiver, callback, market, rate, maturity, size, expiry, and cheap-sale cases.
- Quoter compromise cannot transfer pooled assets outside approved Blue/Midnight/vault paths.
- Curator expansions are timelocked; sentinel reductions are immediate.
- NAV includes Blue yield and conservative Midnight amortized value without double counting.
- Best-effort withdrawal behavior is tested and documented.
- Pilot deployment and rollback runbooks are complete.
- Engineering lead provides final verdict and residual-risk statement.

## 24. Expected evidence from every coding stage

- PR URL and branch/base relationship.
- `gh stack view` output.
- Final commit SHA verified on remote.
- Diff summary and files changed.
- Exact commands run and pass/fail counts.
- Coverage or fuzz/invariant evidence where relevant.
- Security assumptions and residual risks.
- Any deviation from this design, with rationale and explicit lead approval.

## 25. Pinned source links

- Midnight settlement: https://github.com/morpho-org/midnight/blob/709dab354d8f03e64effc2a3dcdd08f5013a0758/src/Midnight.sol
- Midnight SetterRatifier: https://github.com/morpho-org/midnight/blob/709dab354d8f03e64effc2a3dcdd08f5013a0758/src/ratifiers/SetterRatifier.sol
- Midnight BlueBuyCallback: https://github.com/morpho-org/midnight/blob/709dab354d8f03e64effc2a3dcdd08f5013a0758/src/periphery/blue-buy-callback/BlueBuyCallback.sol
- Vault V2 adapter interface: https://github.com/morpho-org/vault-v2/blob/bec4dd8c847525efea95e106b38a70eaabeef65f/src/interfaces/IAdapter.sol
- Vault V2 Morpho Blue adapter reference: https://github.com/morpho-org/vault-v2/blob/bec4dd8c847525efea95e106b38a70eaabeef65f/src/adapters/MorphoMarketV1AdapterV2.sol
- GitHub stacked PR CLI: https://gh.io/stacks
