# Operations

This repository produces immutable `BlueMidnightAdapter` instances. Stage 6 adds a
permissionless CREATE2 factory and operator-facing deployment workflow. Mainnet
use remains blocked until an independent Solidity review is complete and the
Engineering lead explicitly approves deployment.

## Preflight

1. Confirm the approved stack base is `stack/05-exits-liquidity`.
2. Pin the target chain, USDC address, Vault V2 address, Morpho Blue address,
   Midnight address, and ratifier address in an operator change record.
3. Confirm the Vault V2 asset is the same USDC used by the approved Blue market
   and every enabled Midnight market.
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
2. Set conservative global and target exposure caps.
3. Configure each exact Midnight market's economic policy.
4. Enable each market only after its economic policy is configured.
5. Set the quoter and root limits; roots are epoch-bound.
6. Exercise allocation, callback, repayment, safe-exit, and exact deallocation
   paths on the deterministic local deployment.
7. Add the adapter to Vault V2 with low absolute and relative caps.

The sentinel may only tighten policy, disable markets, revoke quoters, bump the
risk-off epoch, and lower limits. Repayment collection remains available during
risk-off.

## Monitoring

Alert on:

- `PolicyEpochIncremented`, `QuoterSet`, `MarketPolicySet`, and risk-off events;
- Blue liquidity and adapter supply assets;
- aggregate and per-market Midnight exposure;
- active market count versus `maxActiveMarkets`;
- book value, maturity claims, recognized losses, and realized P&L;
- failed or reverted exact withdrawals;
- roots that are close to expiry or invalidated by an epoch change.

Operator views include `realAssets`, `expectedSupplyAssets`,
`blueAvailableLiquidity`, `buyerAssetsBound`, `marketAccounting`,
`activeMarketIdsLength`, and `activeMarketIdAt`.

## Risk-off and rollback

1. Revoke the quoter and call `riskOff` with a recorded reason.
2. Disable new Midnight markets and lower Vault allocation caps to zero.
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
attempting recovery. Do not run a mainnet migration while an independent audit
finding is unresolved.
