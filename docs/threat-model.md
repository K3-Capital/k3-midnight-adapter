# Threat model

## Scope and trust boundaries

The adapter is an immutable, single-parent strategy contract. The parent Vault
V2 owns the economic claim and is the only caller allowed to allocate or
deallocate. Morpho Blue and Midnight are external protocols whose pinned
interfaces and callback ordering are assumptions that must be checked again
when dependencies change.

The curator controls policy expansion only through selector-specific timelocks.
The sentinel can reduce risk immediately but cannot expand it. The quoter may
only approve or revoke roots through the adapter; it is not authorized in
Midnight or Morpho Blue and cannot select a receiver, callback, market, or
arbitrary external call.

## Assets and allowed flows

USDC may leave the adapter only to:

- supply to the one curator-approved Morpho Blue market;
- settle a validated Midnight buy;
- return exact assets to the parent vault during deallocation.

Midnight sells pin both the seller and proceeds receiver to the adapter before
the callback. Repayments return to the adapter and are resupplied to Blue.
There is no curator, quoter, or operator rescue path for primary assets.

## Threats and controls

| Threat | Control and evidence |
| --- | --- |
| Compromised quoter drains pooled assets | Quoter has root-management only; adapter validates maker, callback, receiver, market, epoch, and economics. |
| Malicious sell order redirects proceeds | `receiverIfMakerIsSeller == adapter`, `reduceOnly`, minimum exit tick, and callback caller checks. |
| Stale root after policy change | Root approvals are bound to non-zero `policyEpoch`; every accepted change increments the epoch. |
| Curator instant risk expansion | Expansion selectors use exact calldata timelocks; sentinel can revoke pending data. |
| Sentinel expands risk | Sentinel entry points only tighten policy, disable the pinned market, revoke quoters, or activate risk-off. The parent Vault adapter cap is the sole concentration boundary. |
| Arbitrary Blue routing | Adapter stores one market and rejects callback routing data that is not empty. |
| NAV double count during Blue/Midnight transitions | NAV is adapter cash plus expected Blue supply assets plus bounded conservative market book value; transition tests cover allocation, callbacks, repayment, and exits. |
| Known protocol loss hidden in NAV | Callback and checkpoint synchronization reduces tracked claims/book value when Midnight or Blue state loses value. |
| Illiquid withdrawal silently underpays | Normal withdrawal and safe-exit fallback require the exact requested asset amount or revert. |
| Unbounded gas denial | The adapter has one immutable Midnight market, so `realAssets()` has no market loop; callers supply bounded repayment/exit arrays. |
| Reentrancy during external protocol calls | State and caps are checked before transfers; callback entry points require Midnight; no generic external-call primitive exists. |
| Allowance theft | Allowances are exact-reset for Midnight settlement; quoter is never a spender of adapter assets. |

## Residual risks

- Synchronous withdrawals are best effort and can revert during a Blue liquidity
  run; v1 does not promise 100% instant redemption.
- Midnight and Morpho Blue correctness, oracle/economic behavior, and availability
  remain external dependencies.
- The local integration suite is deterministic and does not replace a fork or
  independent audit.
- Mainnet deployment is explicitly blocked until a formal independent external
  audit is complete, blocker/high findings are remediated or formally
  dispositioned, and explicit written deployment approval is recorded. The
  implementation review of this stack and its local evidence is separate from,
  and cannot substitute for, that external audit.
- Operator environment variables and RPC endpoints must be supplied out of
  band; no secrets or deployment state belong in this repository.

## Review checklist

Before release, the implementation reviewer should independently verify
constructor immutables, every external call and callback ordering, accounting
bounds and rounding, timelock selector binding, root epoch invalidation,
receiver pinning, exact-or-revert exits, constant-time market accounting, all
invariant handlers, and deterministic ABI artifacts. Record implementation
findings and their remediation commit in the release change record. Separately,
obtain the formal independent external audit and record its findings,
remediation/disposition, and explicit deployment approval; neither local
implementation review nor passing tests is that approval.
