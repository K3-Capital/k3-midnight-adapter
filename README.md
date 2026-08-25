# K3 Midnight Adapter

Foundry scaffold for the permissionless Morpho Vault V2 / Midnight adapter described in [`docs/design.md`](docs/design.md).

The adapter is deployed directly with an immutable parent Vault, asset, Blue
market, Midnight market, economic policy, ratifier, and approved quoter. Risk
reduction is limited to one-way risk-off, epoch invalidation, quoter revocation,
and Vault-governed policy tightening. Configuration changes require a replacement
adapter and Vault V2's normal timelocked registration/cap process.

## Pinned dependencies

| Dependency | Revision |
| --- | --- |
| Midnight | `709dab354d8f03e64effc2a3dcdd08f5013a0758` |
| Morpho Vault V2 | `bec4dd8c847525efea95e106b38a70eaabeef65f` |
| Morpho Blue | `d09dd1c4b9c7d9d05f976faa7ebfdc424dae5e8c` |
| forge-std | `680ee6692649dcc7c617e05b2144932618264a83` |

Initialize submodules and run:

```bash
git submodule update --init --recursive
forge fmt --check
forge build
forge test --summary
```
