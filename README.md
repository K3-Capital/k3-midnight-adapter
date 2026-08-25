# K3 Midnight Adapter

Foundry scaffold for the permissionless Morpho Vault V2 / Midnight adapter described in [`docs/design.md`](docs/design.md).

This Stage 1 branch intentionally contains no production behavior. It pins the upstream source graph and proves that the Vault V2, Midnight, and Morpho Blue interfaces compile together. Later stack layers add behavior in dependency order.

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
