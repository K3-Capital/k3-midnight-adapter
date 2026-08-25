# Operations

This repository produces immutable `BlueMidnightAdapter` instances. Each instance
is deployed directly by an operator from a fully reviewed constructor configuration.

**Release gate: mainnet deployment is blocked pending a formal independent
external audit, remediation or disposition of its findings, and explicit written
deployment approval from the Engineering lead.** An implementation review (the
stack/PR review, local tests, invariant evidence, and ABI verification) is
necessary release evidence but is not the formal external audit and does not
authorize mainnet deployment.

## Stage 6 release evidence

Export and verify the deterministic ABI artifacts after every Solidity change:

```bash
python3 script/export_abis.py --write  # only when intentionally refreshing artifacts
python3 script/export_abis.py --check
```

The checked artifacts cover `BlueMidnightAdapter` and `PolicySetterRatifier`, including their
events/errors. `docs/abi/operator-views.json` records the required operator
views: `realAssets`, `expectedSupplyAssets`, `blueAvailableLiquidity`,
`buyerAssetsBound`, `accounting`, `pinnedMidnightMarketId`, and
`pinnedMidnightMarketHash`. The script rebuilds production sources with tests skipped,
sorts ABI entries and keys, and fails on drift or a missing operator view.

## Clean-checkout validation

The local integration deploys the pinned Vault V2, Morpho Blue, and Midnight
implementations. Foundry's `--use <version>` resolver downloads the required
compiler into its own cache; no `${HOME}/.svm` layout or preinstalled compiler
path is required. Generated core artifacts are disposable and ignored.

```bash
forge clean
rm -rf out-pinned
./script/build-pinned-core-artifacts.sh
forge fmt --check
forge build
forge test --match-path 'test/integration/**' -vvv
forge test --summary
python3 script/check_release_gate.py
python3 test/test_check_release_gate.py
```

The script uses temporary source roots and removes them on exit. If compiler
downloads are unavailable, install the pinned compiler versions through the
normal Foundry toolchain or provide network access, then rerun the same
sequence; do not commit `out/`, `out-pinned/`, or compiler caches.

The release gate forcibly selects the named `deployment` profile (Solidity
0.8.34, Osaka EVM, optimizer runs 200, via-IR) and rebuilds before measuring
artifacts. It rejects `BlueMidnightAdapter` at 20,000 runtime bytes or above,
and rejects every deployable production contract at the EIP-170 limit of
24,576 bytes. The current measurements are:

| Contract | Runtime bytes | Creation bytes |
| --- | ---: | ---: |
| `BlueMidnightAdapter` | 18,991 | 23,307 |
| `PolicySetterRatifier` | 4,229 | 4,362 |

Run the gate from a clean checkout; its `out/` output is disposable and ignored.

## Preflight

1. Confirm the approved stack base is `simplify/04-immutable-deployment` at the
   exact lead-approved commit recorded in the change record.
2. Pin the target chain, USDC address, Vault V2 address, Morpho Blue address,
   Midnight address, and ratifier address in an operator change record.
3. Confirm the Vault V2 asset is the same token used by the approved Blue market
   and the one immutable Midnight market. The parent Vault adapter cap is the
   sole concentration boundary; the adapter has no internal exposure cap.
4. Encode the exact Blue market, Midnight market, economic policy, and approved
   quoter identity; record the expected runtime code hash.
5. Deploy directly with `script/DeployPilot.s.sol`. Do not commit broadcast
   directories or deployment state.

## Deterministic pilot deployment

The deployment is intentionally nondeterministic unless an established audited
CREATE2 deployer is selected outside this repository. No custom factory or
embedded creation bytecode is used.

```bash
export PARENT_VAULT=0x...
export BLUE_MARKET=0x...
export MIDNIGHT=0x...
export MORPHO_BLUE=0x...
export RATIFIER=0x...
export MIDNIGHT_MARKET=0x...
export ECONOMIC_POLICY=0x...
export APPROVED_QUOTER=0x...
export EXPECTED_RUNTIME_CODE_HASH=0x...
forge script script/DeployPilot.s.sol --rpc-url "$RPC_URL" --broadcast
```

The script verifies every constructor value and runtime code hash before the
deployment is accepted for Vault registration. Query `parentVault`, `asset`,
`midnight`, `morphoBlue`, `ratifier`, `rootApprover`, and both market IDs.

The root approver EOA can only relay root approval/revocation. Safe-administered
policy setters control `maxBuyTick`, `minSellTick`, and `maxExpiryHorizon`; each
accepted change increments the policy epoch and invalidates prior roots. The
sentinel's `pauseNewExposure` is monotonic: it stops new buys, approvals, and
allocation while preserving exits and recovery.

The current build reports 16,940 runtime bytes and 20,799 creation bytes. The
runtime delta versus the approved Stage 3 measurement (18,991 bytes) is -2,051
bytes. `runtime_bytes * 200` is only the EVM runtime code-deposit component
(3,388,000 gas). The reproducible local direct-CREATE fixture is:

```sh
forge test --match-path test/unit/DeployPilot.t.sol \
  --match-test testDirectDeploymentRecordsReproducibleConstructorGas -vvvv
```

It reports 4,151,152 gas for the constructor transaction in Foundry's local
EVM. This is a reproducible fixture measurement, not a target-chain receipt;
production total gas must still be captured from the target-chain transaction
receipt or a chain-specific gas estimate.

## Initial configuration

The constructor pins the single approved Morpho Blue market, economic policy,
quoter, and Midnight market. Vault V2 governance must:

1. Verify the constructor and code hash.
2. Add and cap the adapter through the Vault V2 timelock.
3. Exercise allocation, callback, repayment, asynchronous maker-sell, and exact
   deallocation paths on the deterministic local deployment.

The curator may change policy in either direction for the pinned market, while the
sentinel may permanently pause new exposure. The root approver may revoke roots
even after pause; recovery-root approval is restricted to the curator or sentinel.
Repayment collection remains available during the exposure pause.

## Monitoring

Alert on:

- `PolicyEpochIncremented`, `RootApproverRevoked`, `MaxBuyTickUpdated`,
  `MinSellTickUpdated`, `MaxExpiryHorizonUpdated`, and `NewExposurePaused` events;
- Blue liquidity and adapter supply assets;
- the parent Vault adapter allocation/cap;
- book value, maturity claims, recognized losses, and realized P&L;
- failed or reverted exact withdrawals;
- roots that are close to expiry or invalidated by an epoch change.

Operator views include `realAssets`, `expectedSupplyAssets`,
`blueAvailableLiquidity`, `immediateLiquidity`, `buyerAssetsBound`, `accounting`,
`pinnedMidnightMarketId`, and `pinnedMidnightMarketHash`.

## Risk-off and rollback

1. Revoke the quoter and call `riskOff` with a recorded reason.
2. Lower the parent Vault adapter allocation cap to zero.
3. Continue permissionless repayment collection.
4. Withdraw available Blue liquidity.
5. Have a Vault sentinel approve a policy-valid reduce-only maker-sell recovery
   root for the adapter's exact
   position. An external taker fills the approved offer directly through
   Midnight `take`; verify proceeds were resupplied to Blue, then retry the
   Vault withdrawal in a later transaction.
6. Remove the adapter from Vault V2 only after actual and tracked positions are
   zero.

Never use an emergency path to transfer USDC, Blue shares, or Midnight credit to
an operator, curator, quoter, or arbitrary receiver.

## Migration and incident handling

A configuration change requires a replacement adapter. Deploy the new immutable
adapter, verify its configuration and code hash, add and cap it through Vault V2
governance, then risk-off/deallocate the old adapter as liquidity permits. Remove
the old adapter only after tracked and actual positions are zero. Preserve the
incident timeline, event logs, exact calldata, and local reproduction before
trying recovery. Do not run a mainnet migration while the formal external audit
is incomplete, an audit finding is unresolved, or written deployment approval is
absent.
