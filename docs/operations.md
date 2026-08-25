# Operations

This repository produces immutable `BlueMidnightAdapter` instances. Stage 6 adds a
permissionless CREATE2 factory and operator-facing deployment workflow.

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

The checked artifacts cover `BlueMidnightAdapter`,
`BlueMidnightAdapterFactory`, and `PolicySetterRatifier`, including their
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
```

The script uses temporary source roots and removes them on exit. If compiler
downloads are unavailable, install the pinned compiler versions through the
normal Foundry toolchain or provide network access, then rerun the same
sequence; do not commit `out/`, `out-pinned/`, or compiler caches.

## Preflight

1. Confirm the approved stack base is `stack/05-exits-liquidity`.
2. Pin the target chain, USDC address, Vault V2 address, Morpho Blue address,
   Midnight address, and ratifier address in an operator change record.
3. Confirm the Vault V2 asset is the same token used by the approved Blue market
   and the one immutable Midnight market. The parent Vault adapter cap is the
   sole concentration boundary; the adapter has no internal exposure cap.
4. Deploy `BlueMidnightAdapterFactory` with `script/DeployFactory.s.sol`.
5. Record the factory address and transaction hash in the change record. Do not
   commit broadcast directories or deployment state.

## Deterministic pilot deployment

Use a non-zero, change-controlled `ADAPTER_SALT`. The factory prediction includes
all constructor arguments in the CREATE2 init code, so reusing a salt with a
different configuration yields a different address.

```bash
export ADAPTER_FACTORY=0x...
export ADAPTER_SALT=0x...
export PARENT_VAULT=0x...
export MIDNIGHT=0x...
export MORPHO_BLUE=0x...
export RATIFIER=0x...
forge script script/DeployPilot.s.sol --rpc-url "$RPC_URL" --broadcast
```

Verify the emitted `AdapterDeployed` event and query the adapter's immutable
`parentVault`, `asset`, `midnight`, `morphoBlue`, `ratifier`, and `factory`
values before any Vault registry change.

## Initial configuration

Configure the adapter through Vault V2's curator with the required timelocks:

1. Set the single approved Morpho Blue market.
2. Configure the pinned Midnight market's economic policy.
3. Set the quoter and root limits; roots are epoch-bound.
4. Exercise allocation, callback, repayment, safe-exit, and exact deallocation
   paths on the deterministic local deployment.
5. Add the adapter to Vault V2 with the approved absolute and relative cap.

The sentinel may only tighten policy, disable markets, revoke quoters, bump the
risk-off epoch, and lower limits. Repayment collection remains available during
risk-off.

## Monitoring

Alert on:

- `PolicyEpochIncremented`, `QuoterSet`, `MarketPolicySet`, and risk-off events;
- Blue liquidity and adapter supply assets;
- the parent Vault adapter allocation/cap;
- book value, maturity claims, recognized losses, and realized P&L;
- failed or reverted exact withdrawals;
- roots that are close to expiry or invalidated by an epoch change.

Operator views include `realAssets`, `expectedSupplyAssets`,
`blueAvailableLiquidity`, `buyerAssetsBound`, `accounting`,
`pinnedMidnightMarketId`, and `pinnedMidnightMarketHash`.

## Risk-off and rollback

1. Revoke the quoter and call `riskOff` with a recorded reason.
2. Lower the parent Vault adapter allocation cap to zero.
3. Continue permissionless repayment collection.
4. Withdraw available Blue liquidity.
5. Use only policy-valid safe exits that pin the adapter as receiver and remain
   within the configured loss bound.
6. Remove the adapter from Vault V2 only after actual and tracked positions are
   zero.

Never use an emergency path to transfer USDC, Blue shares, or Midnight credit to
an operator, curator, quoter, or arbitrary receiver.

## Migration and incident handling

A Blue market change is timelocked and cannot activate while the old market has
supply. Revoke pending changes when incident response requires it. Preserve the
incident timeline, event logs, exact calldata, and local reproduction before
trying recovery. Do not run a mainnet migration while the formal external audit
is incomplete, an audit finding is unresolved, or written deployment approval is
absent.
