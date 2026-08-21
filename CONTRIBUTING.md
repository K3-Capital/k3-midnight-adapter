# Contributing

## Stacked implementation workflow

This repository is delivered as six ordered pull requests using GitHub's official `gh stack` extension:

1. `stack/01-foundation` — Foundry scaffold and pinned dependency compatibility.
2. `stack/02-policy-ratifier` — epoch-bound maker root ratification.
3. `stack/03-blue-adapter-core` — Vault V2 adapter and Morpho Blue liquidity.
4. `stack/04-callbacks-accounting` — Midnight callbacks, offer policy, and NAV.
5. `stack/05-exits-liquidity` — repayments, safe exits, and best-effort liquidity.
6. `stack/06-integration-release` — factory, integration tests, deployment, and release readiness.

Install the extension in a writable cache directory:

```bash
export XDG_DATA_HOME="${K3_AGENT_CACHE_DIR:-$PWD/.cache}/gh-xdg"
mkdir -p "$XDG_DATA_HOME"
gh extension install github/gh-stack || gh extension upgrade github/gh-stack
gh stack --version
```

Initialize Stage 1 from `main`, implement and validate it, then submit the stack:

```bash
gh stack init --base main stack/01-foundation
gh stack submit --auto --open
```

Each later stage starts from its approved predecessor. Do not merge an intermediate PR independently unless the stack reports a safe plan and the Engineering lead authorizes it. Never commit secrets, `.env` files, deployment state, RPC credentials, or runtime artifacts.
