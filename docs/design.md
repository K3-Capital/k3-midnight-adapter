# K3 Midnight Adapter — current release design

**Status:** Current implementation design for the approved simplification stack
**Repository:** `https://github.com/K3-Capital/k3-midnight-adapter`  
**Stack:** `simplify/01-single-market` → `simplify/02-scalar-accounting` → `simplify/03-asynchronous-exits` → `simplify/04-immutable-deployment` → `simplify/05-release-hardening`

This document replaces the original oversized design baseline. It describes the
code currently in `src/` and the release/operator contract; it is not a proposal
for additional production behavior.

## Architecture

Each `BlueMidnightAdapter` instance binds exactly one parent Vault V2, one asset,
one Morpho Blue market, one Midnight market, one `PolicySetterRatifier`, one
economic policy, and one approved quoter in its constructor. The adapter is the
Midnight maker and the owner of its lender credit. Vault V2's adapter allocation
and cap are the sole concentration boundary; there is no adapter-local market
registry or exposure-cap layer.

`PolicySetterRatifier` validates the Midnight caller, maker, root epoch, Merkle
proof, exact offer hash, and the maker's live `acceptsOffer` policy. The adapter
keeps the root epoch and position state needed for the pinned market only.

The custom factory and generic selector/calldata governance surface are absent.
Deployment is a direct constructor transaction from `script/DeployPilot.s.sol`.
Changing immutable configuration means deploying a replacement adapter, verifying
its code/configuration, registering it through Vault V2 governance, and retiring
the old adapter only after tracked and actual positions reach zero.

## Asset and callback flows

- `allocate` and `deallocate` accept calls only from the immutable parent Vault.
- Allocation supplies assets to the pinned Morpho Blue market.
- `onBuy` accepts calls only from the pinned Midnight contract, withdraws the
  exact buyer assets from the pinned Blue position, and records scalar claim and
  book-value state before approving Midnight for the exact amount.
- `onSell` pins the adapter as seller and proceeds receiver, reduces the scalar
  claim, records realized P&L, and resupplies proceeds to the pinned Blue market.
- `collectRepayment` is permissionless, keeps proceeds in the adapter, updates
  accounting, and recycles assets to Blue.
- `deallocate` uses adapter cash and currently withdrawable Blue liquidity only.
  It reverts atomically when exact requested liquidity is unavailable; it never
  performs a Midnight sale as part of a Vault withdrawal.

## Valuation and liquidity

`realAssets()` reports adapter cash, expected pinned-Blue supply assets, and
conservative scalar Midnight book value. `immediateLiquidity()` reports only
adapter cash plus currently withdrawable Blue liquidity. Open Midnight face value
and hypothetical sale proceeds are excluded from immediate liquidity. Accounting
checkpoints recognize known Midnight losses and Blue effects without principal-only
realization or double-counting expected yield.

The operator views are `realAssets`, `expectedSupplyAssets`,
`blueAvailableLiquidity`, `immediateLiquidity`, `buyerAssetsBound`, `accounting`,
`pinnedMidnightMarketId`, and `pinnedMidnightMarketHash`.

## Roles and monotonic emergency controls

- The parent Vault owns the economic claim and controls allocation/deallocation.
- Vault governance adds and caps the adapter; the cap is the exposure boundary.
- The curator and sentinel can only apply policy-tightening actions permitted by
  the adapter and Vault roles.
- The sentinel can activate irreversible `riskOff`, invalidate the current root
  epoch, revoke the approved quoter, and approve a recovery root only after
  emergency state is active.
- Risk-off and quoter revocation block new buys while repayment and policy-valid
  reduce-only maker-sell recovery remain available. No emergency function moves
  primary assets to an operator, curator, quoter, or arbitrary receiver.

## Deployment and operations

The deployment script verifies every constructor identity, complete Blue and
Midnight market values, economic policy, approved quoter, and expected runtime
code hash before an operator accepts the deployment for Vault registration. The
release gate uses the named `deployment` Foundry profile and enforces the adapter
runtime budget plus EIP-170 for every deployable production contract.

Normal migration is: deploy replacement → verify constructor/code hash and ABI →
add and cap through Vault V2 governance → allocate gradually → risk-off and
recover/deallocate the old adapter → remove it after zero tracked and actual
positions. Monitoring covers risk-off/epoch/quoter events, Blue liquidity,
parent-Vault cap, book value, claims, losses, P&L, failed exact withdrawals, and
roots nearing expiry.

## Security assumptions and residual risks

The pinned Midnight and Morpho Blue implementations, callback ordering, and
external economic behavior remain protocol assumptions. Withdrawals are best
effort and can revert during a liquidity run; operators must prepare repayment or
a policy-valid asynchronous maker sell. Local integration and invariant tests do
not replace a fork test or a formal independent audit. Mainnet deployment remains
blocked until an external audit is complete, findings are remediated or formally
dispositioned, and written deployment approval is recorded.

No secrets, deployment state, broadcast artifacts, or target-network addresses
belong in this repository. Target-chain receipt gas and fork validation are
reported separately when stable RPC access and approved deployed addresses exist.

## Verification contract

A clean checkout runs:

```bash
forge clean
./script/build-pinned-core-artifacts.sh
forge fmt --check
forge build
forge build --sizes
python3 script/check_release_gate.py
python3 test/test_check_release_gate.py
forge test --match-path 'test/unit/**' -vvv
forge test --match-path 'test/fuzz/**' -vvv
forge test --match-path 'test/invariant/**' -vvv
forge test --match-path 'test/integration/**' -vvv
forge test --summary
python3 script/export_abis.py --check
git diff --check
```

The final release evidence and invariant mapping are recorded in
`docs/reviews/stage6-independent-review.md`; operator procedures are in
`docs/operations.md` and threat boundaries are in `docs/threat-model.md`.
