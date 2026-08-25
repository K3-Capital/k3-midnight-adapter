# K3 Midnight Adapter

Foundry scaffold for the permissionless Morpho Vault V2 / Midnight adapter described in [`docs/design.md`](docs/design.md).

The adapter is deployed directly with an immutable parent Vault, asset, Blue
market, Midnight market, economic policy, ratifier, and hot root-approver EOA.
New exposure can be paused permanently; revocation, repayment, deallocation,
and reduce-only recovery remain available. Policy changes are narrow Safe/Vault
curator operations and increment the epoch, while deployment of a replacement
adapter is the only recovery path for the immutable identities.

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
python3 script/check_release_gate.py
python3 script/export_abis.py --check
```

Release bytecode is measured only with the deterministic `deployment` profile
(Solidity 0.8.34, Osaka EVM, optimizer runs 200, via-IR). The gate rejects
`BlueMidnightAdapter` at 20,000 runtime bytes and every deployable production
contract at EIP-170's 24,576-byte limit. Generated Foundry output is disposable
and must not be committed.
