## Final release-hardening evidence and invariant map

**Review scope:** final single-market Vault-capped, scalar-NAV, asynchronous-exit,
immutable-deployment architecture in this repository. This replaces the earlier
Stage 5 → Stage 6 review note; it is not a formal independent external audit.

### Stack and approval ancestry

The live stack is ordered as follows:

| Stage | Branch | Head | Base |
| --- | --- | --- | --- |
| 1 | `simplify/01-single-market` | `98365381a9ac6f2b24fe7d662589943bbca8180c` | `main` |
| 2 | `simplify/02-scalar-accounting` | `9ccbc632abd5eadbbdae992581355d4ca6100605` | Stage 1 |
| 3 | `simplify/03-asynchronous-exits` | `c4fbd051a7dbea5d787a8fa358b3f8dca5c21625` | Stage 2 |
| 4 | `simplify/04-immutable-deployment` | `8f2c695b93fc8985987d09ce5e38854daa0e0540` | Stage 3 |
| 5 | `simplify/05-release-hardening` | exact correction head is recorded by `git rev-parse HEAD` and the KOP-230 handoff comment | Stage 4 |

PR #15 is lead-approved at the exact Stage 4 head. PR #16 is the release layer
above it; no stage is based on `main` or on an unapproved predecessor.

### KOP-225 invariant mapping

1. **Only the parent Vault may allocate/deallocate.**
   `BlueMidnightAdapter.allocate` and `deallocate` enforce `msg.sender ==
   parentVault` (`src/BlueMidnightAdapter.sol`). Coverage: `testOnlyParentCanAllocate`,
   `testAllocationAndDeallocationReturnAssetsThroughAdapter`, and
   `testFullVaultMorphoMidnightLifecycle`.

2. **No curator/quoter arbitrary asset authority.**
   Constructor-pinned roles expose no arbitrary transfer, receiver, recovery, or
   external-call primitive. Root management is checked by the adapter and ratifier;
   recovery is sentinel-only and policy-valid. Coverage: `testQuoterCannotApproveRoot`,
   `testQuoterRevocationEnablesSentinelRecoveryRootButNotBuys`,
   `testDeployPilotVerifiesEveryPinnedFieldAndRuntimeHash`, and the ratifier suite.

3. **Buy settlement is pinned to approved Blue and the exact Midnight market.**
   `onBuy`, `buyerAssetsBound`, immutable market checks, and offer policy checks
   reject alternate market/asset/caller combinations. Coverage:
   `testStatefulBuyRejectsUnapprovedAndMismatchedRoots`,
   `testOtherwiseIdenticalOtherMarketIsRejected`, and the full integration lifecycle.

4. **Sale proceeds and repayments return to the adapter and Blue.**
   `onSell` pins seller/receiver, reduces scalar claims, and resupplies proceeds;
   `collectRepayment` keeps the destination fixed to the adapter/Blue flow.
   Coverage: `testSellPinsSellerAndReceiver`, `testPartialSellReducesClaimExactlyOnce`,
   `testRevokedQuoterRecoveryUsesRealRatifierAndMidnight`, and repayment fuzz cases.

5. **NAV recognizes losses and avoids principal-only realization errors.**
   `realAssets`, scalar `accounting`, checkpoint synchronization, and
   `_conservativeBookValue` preserve conservative valuation. Coverage:
   `testLossSynchronizationAndPartialSellPreserveLoss`,
   `testImpairmentThenRepaymentSellAndNewBuyNeverRecoverLoss`,
   `testSharePriceIsContinuousAtFillAndRealization`, and `SolvencyInvariantTest`.

6. **Immediate liquidity excludes open Midnight principal and hypothetical sales.**
   `immediateLiquidity`, Blue availability, and exact-or-revert `deallocate` use
   only adapter cash plus currently withdrawable Blue liquidity. Coverage:
   `testIlliquidDeallocationRevertsWithoutAccountingDrift`,
   `testDeallocateUsesAdapterCashBeforeBlue`, and `testBuyerBoundUsesOnlyVaultAllocationAndBlueLiquidity`.

7. **Risk-off blocks new exposure but preserves repayment/reduction.**
   `riskOff`, epoch invalidation, quoter revocation, `approveRecoveryRoot`, and
   reduce-only policy checks are monotonic. Coverage: `invariant_riskOffCannotBeBypassed`,
   `testRiskOffRejectsBuyButAllowsRepaymentAndReducingSell`,
   `testQuoterRevocationEnablesSentinelRecoveryRootButNotBuys`, and
   `testRiskOffRecoveryRootCannotBeApprovedBeforeEmergency`.

8. **Every production commit is buildable and testable.**
   The deployment profile, hostile-environment regression, pinned artifact builder,
   ABI exporter, release workflow, and clean-checkout procedure enforce this. The
   final validation recorded for the reviewed predecessor was 83 passed, 0 failed,
   0 skipped; both handler invariants executed 4,096 calls with zero reverts.

### Release evidence

- `BlueMidnightAdapter`: 18,991 runtime / 23,307 creation bytes.
- `PolicySetterRatifier`: 4,229 runtime / 4,362 creation bytes.
- Adapter delta: -3,925 runtime bytes versus the approved Stage 3 measurement of
  22,916; no production-size delta from approved Stage 4.
- Runtime code-deposit component: 3,798,200 gas.
- Reproducible local direct-CREATE constructor fixture: 4,151,152 gas; this is
  distinct from a target-chain deployment receipt.
- `python3 script/export_abis.py --check`: 3 deterministic ABI/operator artifacts
  verified; deleted factory and generic timelock surfaces are absent.
- Clean checkout generated pinned Vault V2, Morpho, and Midnight artifacts and
  passed formatting, build, release gate, tests, ABI check, and diff hygiene.
- The hostile gate regression runs with `FOUNDRY_OPTIMIZER_RUNS=1`,
  `FOUNDRY_VIA_IR=false`, `FOUNDRY_EVM_VERSION=paris`, and a Dapp setting; it
  verifies the pinned 200-run/OSAKA/via-IR result remains unchanged.

### Stale-surface and deployment status

The current design is `docs/design.md`; README, operations, and threat-model
references now describe the same immutable one-market architecture. The scan
checks active `src/`, scripts, README, current design, operations, threat model,
ABI artifacts, and workflow surfaces; historical review text is not treated as
active configuration. It confirms no factory source/script, no multi-market
registry, and no generic selector-timelock or arbitrary safe-exit API remains.

Fork validation and target-chain deployment receipt gas remain unverified because
no approved deployed target addresses and stable RPC were available in this run.
Mainnet remains blocked on formal independent external audit, remediation or
formal disposition of findings, and explicit written deployment approval.
