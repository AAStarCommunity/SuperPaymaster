
### nightly prague vs nightly amsterdam: 54 tests differ (1694 vs 1694 result lines)

| # | suite | test | nightly prague | nightly amsterdam | class | failure reason |
|---|---|---|---|---|---|---|
| 1 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_baseline_normalPostOp` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 2 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient` | PASS | FAIL | revert/other | op at the MIN floor must pass validation and execute |
| 3 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient_creditPath` | PASS | FAIL | revert/other | postOp must NOT fail at MIN_POST_OP_GAS on the CREDIT path |
| 4 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_verdict` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 5 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_gasless_balance_mode_op_conservation` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 6 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_withdrawProtocolRevenue_after_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 7 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_forward_mid_bundle_upgrade_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 8 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_rollback_mid_bundle_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 9 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeLoweredMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 10 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeRaisedMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 11 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_forward_prevReleaseContext_usesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 12 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_rollback_prevReleaseSettlesNewContext` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 13 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc1_stays_chargesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 14 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc2_stays_chargesSnapshotFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 15 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc1_to_rc2_forward_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 16 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc2_to_rc1_rollback_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 17 | `SuperPaymasterV542ToRc2MidBundle.t.sol:SuperPaymasterV542ToRc2MidBundleTest` | `test_control_v542_stays_settlesNormally` | PASS | FAIL | assertion | control: no postOp revert: 2 != 0 |
| 18 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_B1_no_oog_band_above_entry_guard` | PASS | FAIL | OOG / no-OOG band | no OOG band: a postOp that passed the entry check must complete: 0x != 0x8890295d |
| 19 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_G_min_post_op_gas_covers_measured_postOp` | PASS | FAIL | assertion | MIN_POST_OP_GAS must cover postOp x 64/63 + margin: 235580 > 200000 |
| 20 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_I8_settle_failure_rolls_back_user_execution_e2e` | PASS | FAIL | assertion | assertion failed |
| 21 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | PASS | FAIL | revert/other | op at the floor must validate and execute |
| 22 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_balance_mode_end_to_end` | PASS | FAIL | revert/other | handleOps |
| 23 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint` | PASS | FAIL | revert/other | control: re-enabled |
| 24 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed` | PASS | FAIL | revert/other | during the 48 h window the current SP keeps working |
| 25 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_stolen_owner_cannot_take_user_funds` | PASS | FAIL | revert/other | control: an op committing to the new rate is sponsored |
| 26 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_maxCost_above_auto_cap_rejected_not_truncated` | PASS | FAIL | revert/other | control: a0 within the cap |
| 27 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_self_drain_blocked_by_escrow_user_still_pays` | PASS | FAIL | assertion | assertion failed |
| 28 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N` | PASS | FAIL | revert/other | T-R14-01: bundle of funded Sybils executes |
| 29 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0` | PASS | FAIL | assertion | T-R14-02: 4th op rejected at validation (balance - lockedOf < x0): 0x65c8fd4d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 |
| 30 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected` | PASS | FAIL | assertion | assertion failed |
| 31 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1404_user_execution_revert_still_pays_and_clears_lock` | PASS | FAIL | assertion | assertion failed |
| 32 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero` | PASS | FAIL | revert/other | bundle succeeds (postOpReverted path) |
| 33 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1406_credit_off_debts_never_increase_on_any_path` | PASS | FAIL | revert/other | funded op sponsored in balance mode |
| 34 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution` | PASS | FAIL | assertion | sweep reaches the sufficient region: 0 <= 0 |
| 35 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled` | PASS | FAIL | assertion | success region reached: 0 <= 0 |
| 36 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_postOpGasLimit_sweep_via_entrypoint` | PASS | FAIL | revert/other | at/above the floor: executed and settled |
| 37 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33` | PASS | FAIL | revert/other | control: v2 token path sponsors |
| 38 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_I8_I9_I10_conservation` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x067567e50000000000000000000000000000000585f7cd5d3627c4d9674e9dbdb2c22a23 args=[1879485820647092361 |
| 39 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x0350e2360000000000000000000000000000000000000000000000000000000000000dcd args=[3533] |
| 40 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_noOOGBand_direct_postOp` | PASS | FAIL | OOG / no-OOG band | no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete: 0x != 0x8890295d; counterexample: calldata=0xceba05ed0000000000000000000000000000000000000000000000000000000000002ecc0 |
| 41 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_fixed_seeds` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 42 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 43 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_large_limits` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 44 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_user_call_reverts` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 45 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_worst_postOp_at_floor` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 46 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_bundle_positions` | PASS | FAIL | assertion | C_WRAP bounds the overhead at every bundle position: 184136 > 5000 |
| 47 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_single_ops` | PASS | FAIL | assertion | postOp really ran in every scenario: 3 != 4 |
| 48 | `SuperPaymasterV55GasParams.t.sol:SuperPaymasterV55GasParamsTest` | `test_settle_floor_keeps_no_oog_band` | PASS | FAIL | OOG / no-OOG band | SETTLE floor: no OOG band above the entry guard: 0x != 0x8890295d |
| 49 | `SuperPaymasterV55ParamRace.t.sol:SuperPaymasterV55ParamRaceTest` | `test_open_executor_param_change_mid_bundle_does_not_harm_admitted_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 50 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_each_path_within_C_POSTOP` | PASS | FAIL | assertion | rule per path: BALANCE first-time user, cold lastTimestamp: 1750000000 < 2179790500 |
| 51 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_C_POSTOP_ge_W_postop_times_1_plus_m` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 52 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_under_all_floor_params` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 53 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_rollback_to_5_5_0_settles_contexts_of_the_new_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 54 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |

### 1.7.1 cancun vs nightly cancun: 0 tests differ (1840 vs 1840 result lines)

| # | suite | test | 1.7.1 cancun | nightly cancun | class | failure reason |
|---|---|---|---|---|---|---|

### 1.7.1 cancun vs nightly prague: 231 tests differ (1840 vs 1694 result lines)

| # | suite | test | 1.7.1 cancun | nightly prague | class | failure reason |
|---|---|---|---|---|---|---|
| 1 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `setUp` | — | SKIP |  |  |
| 2 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_DomainSeparatorParityWithRealAggregator` | PASS | — |  |  |
| 3 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_FraudProofDigestParityAcrossIdsAndSets` | PASS | — |  |  |
| 4 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_InnerCommitmentLayoutParityAgainstRealAggregatorWrite` | PASS | — |  |  |
| 5 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_LegacyThreeParamSelectorIsAbsent` | PASS | — |  |  |
| 6 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_OverIssuedTokenFlipsTheSameProofToRejected` | PASS | — |  |  |
| 7 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_RealDvtVerifierPassesAssertDomainBound` | PASS | — |  |  |
| 8 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_RealDvtVerifierPassesAssertSetBound` | PASS | — |  |  |
| 9 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_BelowThresholdIsRejected` | SKIP | PASS |  |  |
| 10 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_DomainSeparatorParityWithRealAggregator` | SKIP | PASS |  |  |
| 11 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_FraudProofDigestParityAcrossIdsAndSets` | SKIP | PASS |  |  |
| 12 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_InnerCommitmentLayoutParityAgainstRealAggregatorWrite` | SKIP | PASS |  |  |
| 13 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_LegacyThreeParamSelectorIsAbsent` | SKIP | PASS |  |  |
| 14 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_ObsoleteOrPerturbedInnerLayoutIsRejected` | SKIP | PASS |  |  |
| 15 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_OverIssuedTokenFlipsTheSameProofToRejected` | SKIP | PASS |  |  |
| 16 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_PrecompilesAreRealNotInjected` | SKIP | PASS |  |  |
| 17 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_RealDvtVerifierPassesAssertDomainBound` | SKIP | PASS |  |  |
| 18 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_RealDvtVerifierPassesAssertSetBound` | SKIP | PASS |  |  |
| 19 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_WrongAggregateSignatureIsRejected` | SKIP | PASS |  |  |
| 20 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `setUp` | — | SKIP |  |  |
| 21 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_AllowsPartialMask_WhenExcludedSlotIsCompromised` | PASS | — |  |  |
| 22 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_ExitNoticeExcludesSlotOnlyAfterDelay` | PASS | — |  |  |
| 23 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_HappyPath_AllSlotsEligible` | PASS | — |  |  |
| 24 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_KeyRevoked` | PASS | — |  |  |
| 25 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorRoleRevoked` | PASS | — |  |  |
| 26 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeBelowMin` | PASS | — |  |  |
| 27 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeFullyWithdrawn` | PASS | — |  |  |
| 28 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_FreesSlotForNewValidator` | PASS | — |  |  |
| 29 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_OnlyOwner` | PASS | — |  |  |
| 30 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_PreservesKeyBytesForAudit` | PASS | — |  |  |
| 31 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_RevertsForUnknownValidator` | PASS | — |  |  |
| 32 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_RevertsWhen_KeyNotActive` | PASS | — |  |  |
| 33 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_Version_Bumped` | PASS | — |  |  |
| 34 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `setUp` | — | SKIP |  |  |
| 35 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_InitialState` | PASS | — |  |  |
| 36 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroDVTValidator_Reverts` | PASS | — |  |  |
| 37 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroRegistry_Reverts` | PASS | — |  |  |
| 38 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroSuperPaymaster_Reverts` | PASS | — |  |  |
| 39 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_IdentityPoint_Rejected_NotOnCurve` | PASS | — |  |  |
| 40 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_OffCurvePoint_Rejected_NotOnCurve` | PASS | — |  |  |
| 41 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_ChangeSlotForSameValidator_Reverts` | PASS | — |  |  |
| 42 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_OnlyOwner_Reverts` | PASS | — |  |  |
| 43 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_OverwritesExistingSameSlot` | PASS | — |  |  |
| 44 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotAboveMax_Reverts` | PASS | — |  |  |
| 45 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotCollision_Reverts` | PASS | — |  |  |
| 46 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotZero_Reverts` | PASS | — |  |  |
| 47 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_Success` | PASS | — |  |  |
| 48 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_ZeroValidator_Reverts` | PASS | — |  |  |
| 49 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RevokeBLSPublicKey_FreesSlot` | PASS | — |  |  |
| 50 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDVTValidator_OnlyOwner_Reverts` | PASS | — |  |  |
| 51 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDVTValidator_Success` | PASS | — |  |  |
| 52 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDefaultThreshold_ExceedsMax_Reverts` | PASS | — |  |  |
| 53 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetMinThreshold_ExactMax_Success` | PASS | — |  |  |
| 54 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetMinThreshold_ExceedsMax_Reverts` | PASS | — |  |  |
| 55 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetSuperPaymaster_OnlyOwner_Reverts` | PASS | — |  |  |
| 56 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetSuperPaymaster_Success` | PASS | — |  |  |
| 57 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SmallSubgroupPoint_Rejected_NotInSubgroup` | PASS | — |  |  |
| 58 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_ValidG1Point_Registers_Successfully` | PASS | — |  |  |
| 59 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Version` | PASS | — |  |  |
| 60 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `setUp` | — | SKIP |  |  |
| 61 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_Canonical_0x11x32` | PASS | — |  |  |
| 62 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_DistinctMessagesDiffer` | PASS | — |  |  |
| 63 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_Empty` | PASS | — |  |  |
| 64 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_NinetySix` | PASS | — |  |  |
| 65 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_OneByte` | PASS | — |  |  |
| 66 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_UserOpHashLike` | PASS | — |  |  |
| 67 | `BLSLibrary.t.sol:BLSLibrary_Test` | `setUp` | — | SKIP |  |  |
| 68 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_PrecompileRevert_BubblesTypedError` | PASS | — |  |  |
| 69 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_Success_ReturnsDecodedPoint` | PASS | — |  |  |
| 70 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_WrongReturnSize_Reverts` | PASS | — |  |  |
| 71 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_PrecompileRevert_Reverts` | PASS | — |  |  |
| 72 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_Success` | PASS | — |  |  |
| 73 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_WrongReturnSize_Reverts` | PASS | — |  |  |
| 74 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DST_MatchesNobleHashToField` | PASS | — |  |  |
| 75 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DispatchesAndReturnsPoint` | PASS | — |  |  |
| 76 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DistinctMessages_DoNotRevert` | PASS | — |  |  |
| 77 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_MapFailure_Reverts` | PASS | — |  |  |
| 78 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFp2ToG2_PrecompileRevert_Reverts` | PASS | — |  |  |
| 79 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFp2ToG2_Success` | PASS | — |  |  |
| 80 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFpToG1_Success` | PASS | — |  |  |
| 81 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFpToG1_WrongSize_Reverts` | PASS | — |  |  |
| 82 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_Mocked_ReturnsFalse` | PASS | — |  |  |
| 83 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_Mocked_ReturnsTrue` | PASS | — |  |  |
| 84 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_MultiPoint_Packing` | PASS | — |  |  |
| 85 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_PrecompileRevert_Reverts` | PASS | — |  |  |
| 86 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `setUp` | — | SKIP |  |  |
| 87 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_defaultSwitchFalse` | PASS | — |  |  |
| 88 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_nonOwnerSwitchOff_revert` | PASS | — |  |  |
| 89 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_ownerPathAlsoRequiresPoP` | PASS | — |  |  |
| 90 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_ownerPathWorksWithAValidPoP` | PASS | — |  |  |
| 91 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_setSwitch_nonOwner_revert` | PASS | — |  |  |
| 92 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_setSwitch_ownerSucceeds_emitsEvent` | PASS | — |  |  |
| 93 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_mismatchedSender_revert` | PASS | — |  |  |
| 94 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_noDVTRole_revert` | PASS | — |  |  |
| 95 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_validRoleInvalidPoP_revert` | PASS | — |  |  |
| 96 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_validRoleValidPoP_TODO` | PASS | — |  |  |
| 97 | `DVT_BLS.t.sol:DVTBLSTest` | `setUp` | — | SKIP |  |  |
| 98 | `DVT_BLS.t.sol:DVTBLSTest` | `test_BLS_ManualVerify` | PASS | — |  |  |
| 99 | `DVT_BLS.t.sol:DVTBLSTest` | `test_DVT_ProposalFlow` | PASS | — |  |  |
| 100 | `DVT_BLS.t.sol:DVTBLSTest` | `test_Fail_NotValidator` | PASS | — |  |  |
| 101 | `DVT_BLS.t.sol:DVTBLSTest` | `test_QueueSlashWithConsensus_FlagsAndBlocksReplay` | PASS | — |  |  |
| 102 | `DVT_BLS.t.sol:DVTBLSTest` | `test_QueueSlashWithProof_ForwarderFlags` | PASS | — |  |  |
| 103 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `setUp` | — | SKIP |  |  |
| 104 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_AlreadyExecuted_Reverts` | PASS | — |  |  |
| 105 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ExactMinThreshold_Success` | PASS | — |  |  |
| 106 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_MaxThreshold_Success` | PASS | — |  |  |
| 107 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_OwnerCanCall` | PASS | — |  |  |
| 108 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_Success` | PASS | — |  |  |
| 109 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_TargetReverts_PropagatesError` | PASS | — |  |  |
| 110 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ThresholdBelowMin_Reverts` | PASS | — |  |  |
| 111 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ThresholdExceedsMax_Reverts` | PASS | — |  |  |
| 112 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_Unauthorized_Reverts` | PASS | — |  |  |
| 113 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ZeroTarget_Reverts` | PASS | — |  |  |
| 114 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetDefaultThreshold` | PASS | — |  |  |
| 115 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetDefaultThreshold_BelowMin_Reverts` | PASS | — |  |  |
| 116 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetMinThreshold` | PASS | — |  |  |
| 117 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetMinThreshold_TooLow_Reverts` | PASS | — |  |  |
| 118 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `setUp` | — | SKIP |  |  |
| 119 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_AboveThreshold_SurvivesOneSlash` | PASS | — |  |  |
| 120 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_AtExactlyMinStake_StillEjects` | PASS | — |  |  |
| 121 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_BpsIsFrozenAtQueue_LoweringItCannotDiscountAQueuedCase` | PASS | — |  |  |
| 122 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_BpsIsFrozenAtQueue_RaisingItCannotRepriceAQueuedCase` | PASS | — |  |  |
| 123 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_IsPerFinding_SecondExecutionTakesFromWhatIsLeft` | PASS | — |  |  |
| 124 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_A_CommitmentStoredAndReproducible` | PASS | — |  |  |
| 125 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_B_FraudProofSlashesAndEjects` | PASS | — |  |  |
| 126 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_B_RejectsUnanchoredProof` | PASS | — |  |  |
| 127 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_VerifierNotSet_Reverts` | PASS | — |  |  |
| 128 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_DirectRegistryAndDVTUpdateRealState` | SKIP | PASS |  |  |
| 129 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsBadSignatureAndWrongChain` | SKIP | PASS |  |  |
| 130 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsBelowThreshold` | SKIP | PASS |  |  |
| 131 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsExitedValidatorAtVerificationTime` | SKIP | PASS |  |  |
| 132 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsMalformedSignature` | SKIP | PASS |  |  |
| 133 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsReplay` | SKIP | PASS |  |  |
| 134 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_AHealthySetPassesTheGate` | SKIP | PASS |  |  |
| 135 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_LegacyPredecessorIsScannableAndStillBlocksATaintedCarryOver` | SKIP | PASS |  |  |
| 136 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_ModernPredecessorStillGetsTheFullPendingScan` | SKIP | PASS |  |  |
| 137 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_PendingCaseOnTheOldAggregatorBlocksTheCutover` | SKIP | PASS |  |  |
| 138 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_RequiredThresholdCoversTheSlashPathsToo` | SKIP | PASS |  |  |
| 139 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_ScanRefusesToRunWithoutEip2537` | SKIP | PASS |  |  |
| 140 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_TaintedKeyCannotBeCarriedOverToTheNewAggregator` | SKIP | PASS |  |  |
| 141 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_UnderPopulatedFreshDeploymentFailsTheGate` | SKIP | PASS |  |  |
| 142 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_WeakScalarKeysFailTheGate` | SKIP | PASS |  |  |
| 143 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_CancelRestoresTheSignerAndImposesACooldown` | SKIP | PASS |  |  |
| 144 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_ExitNoticeDoesNotHaltAnInFlightProof` | SKIP | PASS |  |  |
| 145 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_MutableProxyVerifierCannotUndoAQueuedCase` | SKIP | PASS |  |  |
| 146 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_PreArmedRotationCannotKillAQueuedCase` | SKIP | PASS |  |  |
| 147 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_QueuedCaseFreezesTheRegistryExitPath` | SKIP | PASS |  |  |
| 148 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_SlashedGuardianIsEjectedFromTheNextRealProof` | SKIP | PASS |  |  |
| 149 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_TotalExposureCeilingSurvivesProposalSlicing` | SKIP | PASS |  |  |
| 150 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_DirectRegistryCallUsesTheSameSchema` | SKIP | PASS |  |  |
| 151 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_FieldsStillBindWithinOneDomain` | SKIP | PASS |  |  |
| 152 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_GenericProposalProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 153 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_LegacyPreImageIsNoLongerAccepted` | SKIP | PASS |  |  |
| 154 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_OneKeyCannotBeSplitAcrossTwoValidatorsEvenWithValidPoPs` | SKIP | PASS |  |  |
| 155 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_PoPCannotBeLiftedByAnotherValidator` | SKIP | PASS |  |  |
| 156 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_PoPDoesNotCarryAcrossAggregators` | SKIP | PASS |  |  |
| 157 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_QueueSlashProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 158 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_RegistryReVerificationAcceptsTheAggregatorPreImage` | SKIP | PASS |  |  |
| 159 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_RepointingRegistryInvalidatesInFlightProofs` | SKIP | PASS |  |  |
| 160 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_ReputationProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 161 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongAggregatorInDomainFails` | SKIP | PASS |  |  |
| 162 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongChainIdInDomainFails` | SKIP | PASS |  |  |
| 163 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongDomainNameFails` | SKIP | PASS |  |  |
| 164 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongPathTagFails` | SKIP | PASS |  |  |
| 165 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongRegistryInDomainFails` | SKIP | PASS |  |  |
| 166 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `setUp` | — | SKIP |  |  |
| 167 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_changedRuntime_rejected` | PASS | — |  |  |
| 168 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_overIssued_rejected` | PASS | — |  |  |
| 169 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_passes` | PASS | — |  |  |
| 170 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_pendingHandover_rejected` | PASS | — |  |  |
| 171 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongCap_rejected` | PASS | — |  |  |
| 172 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongGuardian_rejected` | PASS | — |  |  |
| 173 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongMinter_rejected` | PASS | — |  |  |
| 174 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongNameAndPermitDomain_rejected` | PASS | — |  |  |
| 175 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongName_rejected` | PASS | — |  |  |
| 176 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongOwner_rejected` | PASS | — |  |  |
| 177 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongTimelockDelay_rejected` | PASS | — |  |  |
| 178 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_passes` | PASS | — |  |  |
| 179 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_wrongImplementation_rejected` | PASS | — |  |  |
| 180 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_wrongRuntime_rejected` | PASS | — |  |  |
| 181 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_otherContract_rejected` | PASS | — |  |  |
| 182 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `setUp` | — | SKIP |  |  |
| 183 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_correctTimelock_passes` | PASS | — |  |  |
| 184 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_chunkedHistory_passes` | PASS | — |  |  |
| 185 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_historyStateMismatch_rejected` | PASS | — |  |  |
| 186 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_lateStart_rejected` | PASS | — |  |  |
| 187 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_missingConstructorGrant_rejected` | PASS | — |  |  |
| 188 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_unlistedAdmin_rejected` | PASS | — |  |  |
| 189 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_unorderedLogs_rejected` | PASS | — |  |  |
| 190 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_missingHistory_rejected` | PASS | — |  |  |
| 191 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_postDeploymentUnlistedProposer_rejected` | PASS | — |  |  |
| 192 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_revokedExtraRoles_passes` | PASS | — |  |  |
| 193 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_revokedUnknownRole_rejected` | PASS | — |  |  |
| 194 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_timelock_changedRuntime_rejected` | PASS | — |  |  |
| 195 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_unlistedAdmin_rejected` | PASS | — |  |  |
| 196 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_unlistedExecutor_rejected` | PASS | — |  |  |
| 197 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `setUp` | — | SKIP |  |  |
| 198 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_AccusedGuardianCannotCancelBackIntoSignerSet` | PASS | — |  |  |
| 199 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_AlreadyBelowQuorumDoesNotTrapGuardians` | PASS | — |  |  |
| 200 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExitIsRefusedWhenItWouldBreakQuorum` | PASS | — |  |  |
| 201 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExitNoticeCannotHaltConsensusInTheSameBlock` | PASS | — |  |  |
| 202 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExpiredNoticeIsClearedByCancel` | PASS | — |  |  |
| 203 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorIgnoresGuardiansWhoseStakeFellBelowMinimum` | PASS | — |  |  |
| 204 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorStillAllowsTheExitWhenEveryStakeIsHealthy` | PASS | — |  |  |
| 205 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorUsesTheStrictestThresholdAcrossAllPaths` | PASS | — |  |  |
| 206 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_NonSignerGuardianIsUnaffectedByTheFloor` | PASS | — |  |  |
| 207 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_NoticeAlwaysGivesFullDelayBeforeExclusion` | PASS | — |  |  |
| 208 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_QueuedCaseEmitsTheGuardianSetNotJustItsHash` | PASS | — |  |  |
| 209 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_RepeatedCyclesNeverProduceAHaltedBlock` | PASS | — |  |  |
| 210 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_RequestCancelCycleIsRateLimited` | PASS | — |  |  |
| 211 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_VerifierRotationCanBeCancelledByOwnerOnly` | PASS | — |  |  |
| 212 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_VerifierRotationCannotOutrunAQueuedCase` | PASS | — |  |  |
| 213 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_DistinctKeysStillRegisterNormally` | PASS | SKIP |  |  |
| 214 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_DuplicateRejectionAppliesToTheOwnerPath` | PASS | SKIP |  |  |
| 215 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_KeyBindingIsPerAggregator` | PASS | SKIP |  |  |
| 216 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_OwnerCanReleaseABindingNoActiveSlotUses` | PASS | SKIP |  |  |
| 217 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsOwnerOnlyAndRejectsAnUnknownKey` | PASS | SKIP |  |  |
| 218 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsRefusedWhenTheKeyIsLiveUnderAnotherAddress` | PASS | SKIP |  |  |
| 219 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsRefusedWhileAnActiveSlotHoldsTheKey` | PASS | SKIP |  |  |
| 220 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_RevocationDoesNotReleaseTheKeyBinding` | PASS | SKIP |  |  |
| 221 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_SameKeyCannotBeRegisteredForTwoValidators` | PASS | SKIP |  |  |
| 222 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ValidatorMayReRegisterItsOwnKey` | PASS | SKIP |  |  |
| 223 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `setUp` | — | SKIP |  |  |
| 224 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_DeletedBLSValidator_NoLongerImported` | PASS | — |  |  |
| 225 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_ConsistentAcrossSignerMaskOrderings` | PASS | — |  |  |
| 226 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_ReconstructsFromOnChainPKs_HappyPath` | PASS | — |  |  |
| 227 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsBelowThreshold` | PASS | — |  |  |
| 228 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsBitsBeyondMaxValidators` | PASS | — |  |  |
| 229 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsCallerSuppliedPkAgg_AbiGone` | PASS | — |  |  |
| 230 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsEmptySignerMask` | PASS | — |  |  |
| 231 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsForgedPkAgg_BySlotNotRegistered` | PASS | — |  |  |

### 1.7.1 cancun vs nightly amsterdam: 285 tests differ (1840 vs 1694 result lines)

| # | suite | test | 1.7.1 cancun | nightly amsterdam | class | failure reason |
|---|---|---|---|---|---|---|
| 1 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `setUp` | — | SKIP |  |  |
| 2 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_DomainSeparatorParityWithRealAggregator` | PASS | — |  |  |
| 3 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_FraudProofDigestParityAcrossIdsAndSets` | PASS | — |  |  |
| 4 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_InnerCommitmentLayoutParityAgainstRealAggregatorWrite` | PASS | — |  |  |
| 5 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_LegacyThreeParamSelectorIsAbsent` | PASS | — |  |  |
| 6 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_OverIssuedTokenFlipsTheSameProofToRejected` | PASS | — |  |  |
| 7 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_RealDvtVerifierPassesAssertDomainBound` | PASS | — |  |  |
| 8 | `CC115CrossRepoConformance.t.sol:CC115CrossRepoConformance` | `test_RealDvtVerifierPassesAssertSetBound` | PASS | — |  |  |
| 9 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_BelowThresholdIsRejected` | SKIP | PASS |  |  |
| 10 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_DomainSeparatorParityWithRealAggregator` | SKIP | PASS |  |  |
| 11 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_FraudProofDigestParityAcrossIdsAndSets` | SKIP | PASS |  |  |
| 12 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_InnerCommitmentLayoutParityAgainstRealAggregatorWrite` | SKIP | PASS |  |  |
| 13 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_LegacyThreeParamSelectorIsAbsent` | SKIP | PASS |  |  |
| 14 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_ObsoleteOrPerturbedInnerLayoutIsRejected` | SKIP | PASS |  |  |
| 15 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_OverIssuedTokenFlipsTheSameProofToRejected` | SKIP | PASS |  |  |
| 16 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_PrecompilesAreRealNotInjected` | SKIP | PASS |  |  |
| 17 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_RealDvtVerifierPassesAssertDomainBound` | SKIP | PASS |  |  |
| 18 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_RealDvtVerifierPassesAssertSetBound` | SKIP | PASS |  |  |
| 19 | `CC115GenuinePragueCrossRepo.t.sol:CC115GenuinePragueCrossRepo` | `test_GenuinePrague_WrongAggregateSignatureIsRejected` | SKIP | PASS |  |  |
| 20 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `setUp` | — | SKIP |  |  |
| 21 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_AllowsPartialMask_WhenExcludedSlotIsCompromised` | PASS | — |  |  |
| 22 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_ExitNoticeExcludesSlotOnlyAfterDelay` | PASS | — |  |  |
| 23 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_HappyPath_AllSlotsEligible` | PASS | — |  |  |
| 24 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_KeyRevoked` | PASS | — |  |  |
| 25 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorRoleRevoked` | PASS | — |  |  |
| 26 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeBelowMin` | PASS | — |  |  |
| 27 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeFullyWithdrawn` | PASS | — |  |  |
| 28 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_FreesSlotForNewValidator` | PASS | — |  |  |
| 29 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_OnlyOwner` | PASS | — |  |  |
| 30 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_PreservesKeyBytesForAudit` | PASS | — |  |  |
| 31 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_RevertsForUnknownValidator` | PASS | — |  |  |
| 32 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_RevokeBLSPublicKey_RevertsWhen_KeyNotActive` | PASS | — |  |  |
| 33 | `BLSAggregatorLiveness.t.sol:BLSAggregatorLivenessTest` | `test_Version_Bumped` | PASS | — |  |  |
| 34 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `setUp` | — | SKIP |  |  |
| 35 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_InitialState` | PASS | — |  |  |
| 36 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroDVTValidator_Reverts` | PASS | — |  |  |
| 37 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroRegistry_Reverts` | PASS | — |  |  |
| 38 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Constructor_ZeroSuperPaymaster_Reverts` | PASS | — |  |  |
| 39 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_IdentityPoint_Rejected_NotOnCurve` | PASS | — |  |  |
| 40 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_OffCurvePoint_Rejected_NotOnCurve` | PASS | — |  |  |
| 41 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_ChangeSlotForSameValidator_Reverts` | PASS | — |  |  |
| 42 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_OnlyOwner_Reverts` | PASS | — |  |  |
| 43 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_OverwritesExistingSameSlot` | PASS | — |  |  |
| 44 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotAboveMax_Reverts` | PASS | — |  |  |
| 45 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotCollision_Reverts` | PASS | — |  |  |
| 46 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_SlotZero_Reverts` | PASS | — |  |  |
| 47 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_Success` | PASS | — |  |  |
| 48 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RegisterBLSPublicKey_ZeroValidator_Reverts` | PASS | — |  |  |
| 49 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_RevokeBLSPublicKey_FreesSlot` | PASS | — |  |  |
| 50 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDVTValidator_OnlyOwner_Reverts` | PASS | — |  |  |
| 51 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDVTValidator_Success` | PASS | — |  |  |
| 52 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetDefaultThreshold_ExceedsMax_Reverts` | PASS | — |  |  |
| 53 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetMinThreshold_ExactMax_Success` | PASS | — |  |  |
| 54 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetMinThreshold_ExceedsMax_Reverts` | PASS | — |  |  |
| 55 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetSuperPaymaster_OnlyOwner_Reverts` | PASS | — |  |  |
| 56 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SetSuperPaymaster_Success` | PASS | — |  |  |
| 57 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_SmallSubgroupPoint_Rejected_NotInSubgroup` | PASS | — |  |  |
| 58 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_ValidG1Point_Registers_Successfully` | PASS | — |  |  |
| 59 | `BLSAggregatorUnit.t.sol:BLSAggregatorUnitTest` | `test_Version` | PASS | — |  |  |
| 60 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `setUp` | — | SKIP |  |  |
| 61 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_Canonical_0x11x32` | PASS | — |  |  |
| 62 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_DistinctMessagesDiffer` | PASS | — |  |  |
| 63 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_Empty` | PASS | — |  |  |
| 64 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_NinetySix` | PASS | — |  |  |
| 65 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_OneByte` | PASS | — |  |  |
| 66 | `BLSGoldenVectors.t.sol:BLSGoldenVectors_Test` | `test_Golden_UserOpHashLike` | PASS | — |  |  |
| 67 | `BLSLibrary.t.sol:BLSLibrary_Test` | `setUp` | — | SKIP |  |  |
| 68 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_PrecompileRevert_BubblesTypedError` | PASS | — |  |  |
| 69 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_Success_ReturnsDecodedPoint` | PASS | — |  |  |
| 70 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G1Add_WrongReturnSize_Reverts` | PASS | — |  |  |
| 71 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_PrecompileRevert_Reverts` | PASS | — |  |  |
| 72 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_Success` | PASS | — |  |  |
| 73 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_G2Add_WrongReturnSize_Reverts` | PASS | — |  |  |
| 74 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DST_MatchesNobleHashToField` | PASS | — |  |  |
| 75 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DispatchesAndReturnsPoint` | PASS | — |  |  |
| 76 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_DistinctMessages_DoNotRevert` | PASS | — |  |  |
| 77 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_HashToG2_MapFailure_Reverts` | PASS | — |  |  |
| 78 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFp2ToG2_PrecompileRevert_Reverts` | PASS | — |  |  |
| 79 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFp2ToG2_Success` | PASS | — |  |  |
| 80 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFpToG1_Success` | PASS | — |  |  |
| 81 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_MapFpToG1_WrongSize_Reverts` | PASS | — |  |  |
| 82 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_Mocked_ReturnsFalse` | PASS | — |  |  |
| 83 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_Mocked_ReturnsTrue` | PASS | — |  |  |
| 84 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_MultiPoint_Packing` | PASS | — |  |  |
| 85 | `BLSLibrary.t.sol:BLSLibrary_Test` | `test_Pairing_PrecompileRevert_Reverts` | PASS | — |  |  |
| 86 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `setUp` | — | SKIP |  |  |
| 87 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_defaultSwitchFalse` | PASS | — |  |  |
| 88 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_nonOwnerSwitchOff_revert` | PASS | — |  |  |
| 89 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_ownerPathAlsoRequiresPoP` | PASS | — |  |  |
| 90 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_ownerPathWorksWithAValidPoP` | PASS | — |  |  |
| 91 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_setSwitch_nonOwner_revert` | PASS | — |  |  |
| 92 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_setSwitch_ownerSucceeds_emitsEvent` | PASS | — |  |  |
| 93 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_mismatchedSender_revert` | PASS | — |  |  |
| 94 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_noDVTRole_revert` | PASS | — |  |  |
| 95 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_validRoleInvalidPoP_revert` | PASS | — |  |  |
| 96 | `BLSPermissionlessRegistration.t.sol:BLSPermissionlessRegistrationTest` | `test_switchOn_validRoleValidPoP_TODO` | PASS | — |  |  |
| 97 | `DVT_BLS.t.sol:DVTBLSTest` | `setUp` | — | SKIP |  |  |
| 98 | `DVT_BLS.t.sol:DVTBLSTest` | `test_BLS_ManualVerify` | PASS | — |  |  |
| 99 | `DVT_BLS.t.sol:DVTBLSTest` | `test_DVT_ProposalFlow` | PASS | — |  |  |
| 100 | `DVT_BLS.t.sol:DVTBLSTest` | `test_Fail_NotValidator` | PASS | — |  |  |
| 101 | `DVT_BLS.t.sol:DVTBLSTest` | `test_QueueSlashWithConsensus_FlagsAndBlocksReplay` | PASS | — |  |  |
| 102 | `DVT_BLS.t.sol:DVTBLSTest` | `test_QueueSlashWithProof_ForwarderFlags` | PASS | — |  |  |
| 103 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `setUp` | — | SKIP |  |  |
| 104 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_AlreadyExecuted_Reverts` | PASS | — |  |  |
| 105 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ExactMinThreshold_Success` | PASS | — |  |  |
| 106 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_MaxThreshold_Success` | PASS | — |  |  |
| 107 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_OwnerCanCall` | PASS | — |  |  |
| 108 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_Success` | PASS | — |  |  |
| 109 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_TargetReverts_PropagatesError` | PASS | — |  |  |
| 110 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ThresholdBelowMin_Reverts` | PASS | — |  |  |
| 111 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ThresholdExceedsMax_Reverts` | PASS | — |  |  |
| 112 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_Unauthorized_Reverts` | PASS | — |  |  |
| 113 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_ExecuteProposal_ZeroTarget_Reverts` | PASS | — |  |  |
| 114 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetDefaultThreshold` | PASS | — |  |  |
| 115 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetDefaultThreshold_BelowMin_Reverts` | PASS | — |  |  |
| 116 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetMinThreshold` | PASS | — |  |  |
| 117 | `GenericDVTProposal.t.sol:GenericDVTProposalTest` | `test_SetMinThreshold_TooLow_Reverts` | PASS | — |  |  |
| 118 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `setUp` | — | SKIP |  |  |
| 119 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_AboveThreshold_SurvivesOneSlash` | PASS | — |  |  |
| 120 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_AtExactlyMinStake_StillEjects` | PASS | — |  |  |
| 121 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_BpsIsFrozenAtQueue_LoweringItCannotDiscountAQueuedCase` | PASS | — |  |  |
| 122 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_BpsIsFrozenAtQueue_RaisingItCannotRepriceAQueuedCase` | PASS | — |  |  |
| 123 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_Cap_IsPerFinding_SecondExecutionTakesFromWhatIsLeft` | PASS | — |  |  |
| 124 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_A_CommitmentStoredAndReproducible` | PASS | — |  |  |
| 125 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_B_FraudProofSlashesAndEjects` | PASS | — |  |  |
| 126 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_B_RejectsUnanchoredProof` | PASS | — |  |  |
| 127 | `GuardianSlashE2E.t.sol:GuardianSlashE2ETest` | `test_E2E_VerifierNotSet_Reverts` | PASS | — |  |  |
| 128 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_DirectRegistryAndDVTUpdateRealState` | SKIP | PASS |  |  |
| 129 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsBadSignatureAndWrongChain` | SKIP | PASS |  |  |
| 130 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsBelowThreshold` | SKIP | PASS |  |  |
| 131 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsExitedValidatorAtVerificationTime` | SKIP | PASS |  |  |
| 132 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsMalformedSignature` | SKIP | PASS |  |  |
| 133 | `BLSGasMeasurement.t.sol:RepCreditPragueE2E` | `test_Prague_RejectsReplay` | SKIP | PASS |  |  |
| 134 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_AHealthySetPassesTheGate` | SKIP | PASS |  |  |
| 135 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_LegacyPredecessorIsScannableAndStillBlocksATaintedCarryOver` | SKIP | PASS |  |  |
| 136 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_ModernPredecessorStillGetsTheFullPendingScan` | SKIP | PASS |  |  |
| 137 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_PendingCaseOnTheOldAggregatorBlocksTheCutover` | SKIP | PASS |  |  |
| 138 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_RequiredThresholdCoversTheSlashPathsToo` | SKIP | PASS |  |  |
| 139 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_ScanRefusesToRunWithoutEip2537` | SKIP | PASS |  |  |
| 140 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_TaintedKeyCannotBeCarriedOverToTheNewAggregator` | SKIP | PASS |  |  |
| 141 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_UnderPopulatedFreshDeploymentFailsTheGate` | SKIP | PASS |  |  |
| 142 | `CC48KeyScanPreflight.t.sol:CC48KeyScanPreflight` | `test_WeakScalarKeysFailTheGate` | SKIP | PASS |  |  |
| 143 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_CancelRestoresTheSignerAndImposesACooldown` | SKIP | PASS |  |  |
| 144 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_ExitNoticeDoesNotHaltAnInFlightProof` | SKIP | PASS |  |  |
| 145 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_MutableProxyVerifierCannotUndoAQueuedCase` | SKIP | PASS |  |  |
| 146 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_PreArmedRotationCannotKillAQueuedCase` | SKIP | PASS |  |  |
| 147 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_QueuedCaseFreezesTheRegistryExitPath` | SKIP | PASS |  |  |
| 148 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_SlashedGuardianIsEjectedFromTheNextRealProof` | SKIP | PASS |  |  |
| 149 | `CC48PragueStateMachine.t.sol:CC48PragueStateMachine` | `test_Prague_TotalExposureCeilingSurvivesProposalSlicing` | SKIP | PASS |  |  |
| 150 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_DirectRegistryCallUsesTheSameSchema` | SKIP | PASS |  |  |
| 151 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_FieldsStillBindWithinOneDomain` | SKIP | PASS |  |  |
| 152 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_GenericProposalProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 153 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_LegacyPreImageIsNoLongerAccepted` | SKIP | PASS |  |  |
| 154 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_OneKeyCannotBeSplitAcrossTwoValidatorsEvenWithValidPoPs` | SKIP | PASS |  |  |
| 155 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_PoPCannotBeLiftedByAnotherValidator` | SKIP | PASS |  |  |
| 156 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_PoPDoesNotCarryAcrossAggregators` | SKIP | PASS |  |  |
| 157 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_QueueSlashProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 158 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_RegistryReVerificationAcceptsTheAggregatorPreImage` | SKIP | PASS |  |  |
| 159 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_RepointingRegistryInvalidatesInFlightProofs` | SKIP | PASS |  |  |
| 160 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_ReputationProofDoesNotReplayToAnotherAggregator` | SKIP | PASS |  |  |
| 161 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongAggregatorInDomainFails` | SKIP | PASS |  |  |
| 162 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongChainIdInDomainFails` | SKIP | PASS |  |  |
| 163 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongDomainNameFails` | SKIP | PASS |  |  |
| 164 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongPathTagFails` | SKIP | PASS |  |  |
| 165 | `RepCreditDomainReplay.t.sol:RepCreditDomainReplay` | `test_WrongRegistryInDomainFails` | SKIP | PASS |  |  |
| 166 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `setUp` | — | SKIP |  |  |
| 167 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_changedRuntime_rejected` | PASS | — |  |  |
| 168 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_overIssued_rejected` | PASS | — |  |  |
| 169 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_passes` | PASS | — |  |  |
| 170 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_pendingHandover_rejected` | PASS | — |  |  |
| 171 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongCap_rejected` | PASS | — |  |  |
| 172 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongGuardian_rejected` | PASS | — |  |  |
| 173 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongMinter_rejected` | PASS | — |  |  |
| 174 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongNameAndPermitDomain_rejected` | PASS | — |  |  |
| 175 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongName_rejected` | PASS | — |  |  |
| 176 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongOwner_rejected` | PASS | — |  |  |
| 177 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_cappedToken_wrongTimelockDelay_rejected` | PASS | — |  |  |
| 178 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_passes` | PASS | — |  |  |
| 179 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_wrongImplementation_rejected` | PASS | — |  |  |
| 180 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_legacyClone_wrongRuntime_rejected` | PASS | — |  |  |
| 181 | `CheckDefaultArtifacts.t.sol:CheckDefaultArtifactsTest` | `test_otherContract_rejected` | PASS | — |  |  |
| 182 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `setUp` | — | SKIP |  |  |
| 183 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_correctTimelock_passes` | PASS | — |  |  |
| 184 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_chunkedHistory_passes` | PASS | — |  |  |
| 185 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_historyStateMismatch_rejected` | PASS | — |  |  |
| 186 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_lateStart_rejected` | PASS | — |  |  |
| 187 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_missingConstructorGrant_rejected` | PASS | — |  |  |
| 188 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_unlistedAdmin_rejected` | PASS | — |  |  |
| 189 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_historyScanner_unorderedLogs_rejected` | PASS | — |  |  |
| 190 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_missingHistory_rejected` | PASS | — |  |  |
| 191 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_postDeploymentUnlistedProposer_rejected` | PASS | — |  |  |
| 192 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_revokedExtraRoles_passes` | PASS | — |  |  |
| 193 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_revokedUnknownRole_rejected` | PASS | — |  |  |
| 194 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_timelock_changedRuntime_rejected` | PASS | — |  |  |
| 195 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_unlistedAdmin_rejected` | PASS | — |  |  |
| 196 | `DeployAPNTsCapped.t.sol:DeployAPNTsCappedTest` | `test_unlistedExecutor_rejected` | PASS | — |  |  |
| 197 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `setUp` | — | SKIP |  |  |
| 198 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_AccusedGuardianCannotCancelBackIntoSignerSet` | PASS | — |  |  |
| 199 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_AlreadyBelowQuorumDoesNotTrapGuardians` | PASS | — |  |  |
| 200 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExitIsRefusedWhenItWouldBreakQuorum` | PASS | — |  |  |
| 201 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExitNoticeCannotHaltConsensusInTheSameBlock` | PASS | — |  |  |
| 202 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_ExpiredNoticeIsClearedByCancel` | PASS | — |  |  |
| 203 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorIgnoresGuardiansWhoseStakeFellBelowMinimum` | PASS | — |  |  |
| 204 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorStillAllowsTheExitWhenEveryStakeIsHealthy` | PASS | — |  |  |
| 205 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_FloorUsesTheStrictestThresholdAcrossAllPaths` | PASS | — |  |  |
| 206 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_NonSignerGuardianIsUnaffectedByTheFloor` | PASS | — |  |  |
| 207 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_NoticeAlwaysGivesFullDelayBeforeExclusion` | PASS | — |  |  |
| 208 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_QueuedCaseEmitsTheGuardianSetNotJustItsHash` | PASS | — |  |  |
| 209 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_RepeatedCyclesNeverProduceAHaltedBlock` | PASS | — |  |  |
| 210 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_RequestCancelCycleIsRateLimited` | PASS | — |  |  |
| 211 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_VerifierRotationCanBeCancelledByOwnerOnly` | PASS | — |  |  |
| 212 | `CC48CoreFixes.t.sol:CC48ExitNoticeTest` | `test_VerifierRotationCannotOutrunAQueuedCase` | PASS | — |  |  |
| 213 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_DistinctKeysStillRegisterNormally` | PASS | SKIP |  |  |
| 214 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_DuplicateRejectionAppliesToTheOwnerPath` | PASS | SKIP |  |  |
| 215 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_KeyBindingIsPerAggregator` | PASS | SKIP |  |  |
| 216 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_OwnerCanReleaseABindingNoActiveSlotUses` | PASS | SKIP |  |  |
| 217 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsOwnerOnlyAndRejectsAnUnknownKey` | PASS | SKIP |  |  |
| 218 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsRefusedWhenTheKeyIsLiveUnderAnotherAddress` | PASS | SKIP |  |  |
| 219 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ReleaseIsRefusedWhileAnActiveSlotHoldsTheKey` | PASS | SKIP |  |  |
| 220 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_RevocationDoesNotReleaseTheKeyBinding` | PASS | SKIP |  |  |
| 221 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_SameKeyCannotBeRegisteredForTwoValidators` | PASS | SKIP |  |  |
| 222 | `CC48DomainSeparation.t.sol:CC48PoPBindingTest` | `test_ValidatorMayReRegisterItsOwnKey` | PASS | SKIP |  |  |
| 223 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_baseline_normalPostOp` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 224 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient` | PASS | FAIL | revert/other | op at the MIN floor must pass validation and execute |
| 225 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_minGasFloorIsSufficient_creditPath` | PASS | FAIL | revert/other | postOp must NOT fail at MIN_POST_OP_GAS on the CREDIT path |
| 226 | `PoC_C04_ForcedPostOpOOG.t.sol:PoC_C04_ForcedPostOpOOG_Test` | `test_fix_verdict` | PASS | FAIL | revert/other | baseline handleOps must not revert |
| 227 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_gasless_balance_mode_op_conservation` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 228 | `APNTsCappedSPIntegration.t.sol:APNTsCappedSPIntegrationTest` | `test_SP_withdrawProtocolRevenue_after_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 229 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_forward_mid_bundle_upgrade_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 230 | `SuperPaymasterD5bUpgradeRace.t.sol:SuperPaymasterD5bUpgradeRaceTest` | `test_d5b_rollback_mid_bundle_with_extension_calls` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 231 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeLoweredMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 232 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_feeRaisedMidBundle_chargesValidationFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 233 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_forward_prevReleaseContext_usesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 234 | `SuperPaymasterFeeSnapshot.t.sol:SuperPaymasterFeeSnapshotTest` | `test_feeSnapshot_rollback_prevReleaseSettlesNewContext` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 235 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc1_stays_chargesLiveFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 236 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_control_rc2_stays_chargesSnapshotFee` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 237 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc1_to_rc2_forward_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 238 | `SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest` | `test_rc2_to_rc1_rollback_mid_bundle` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(2, "AA33 reverted", 0x) |
| 239 | `SuperPaymasterV542ToRc2MidBundle.t.sol:SuperPaymasterV542ToRc2MidBundleTest` | `test_control_v542_stays_settlesNormally` | PASS | FAIL | assertion | control: no postOp revert: 2 != 0 |
| 240 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_B1_no_oog_band_above_entry_guard` | PASS | FAIL | OOG / no-OOG band | no OOG band: a postOp that passed the entry check must complete: 0x != 0x8890295d |
| 241 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_G_min_post_op_gas_covers_measured_postOp` | PASS | FAIL | assertion | MIN_POST_OP_GAS must cover postOp x 64/63 + margin: 235580 > 200000 |
| 242 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_I8_settle_failure_rolls_back_user_execution_e2e` | PASS | FAIL | assertion | assertion failed |
| 243 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | PASS | FAIL | revert/other | op at the floor must validate and execute |
| 244 | `SuperPaymasterV55.t.sol:SuperPaymasterV55Test` | `test_balance_mode_end_to_end` | PASS | FAIL | revert/other | handleOps |
| 245 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint` | PASS | FAIL | revert/other | control: re-enabled |
| 246 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed` | PASS | FAIL | revert/other | during the 48 h window the current SP keeps working |
| 247 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_R13_stolen_owner_cannot_take_user_funds` | PASS | FAIL | revert/other | control: an op committing to the new rate is sponsored |
| 248 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_maxCost_above_auto_cap_rejected_not_truncated` | PASS | FAIL | revert/other | control: a0 within the cap |
| 249 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_RouteA_self_drain_blocked_by_escrow_user_still_pays` | PASS | FAIL | assertion | assertion failed |
| 250 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N` | PASS | FAIL | revert/other | T-R14-01: bundle of funded Sybils executes |
| 251 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0` | PASS | FAIL | assertion | T-R14-02: 4th op rejected at validation (balance - lockedOf < x0): 0x65c8fd4d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 |
| 252 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected` | PASS | FAIL | assertion | assertion failed |
| 253 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1404_user_execution_revert_still_pays_and_clears_lock` | PASS | FAIL | assertion | assertion failed |
| 254 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero` | PASS | FAIL | revert/other | bundle succeeds (postOpReverted path) |
| 255 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1406_credit_off_debts_never_increase_on_any_path` | PASS | FAIL | revert/other | funded op sponsored in balance mode |
| 256 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution` | PASS | FAIL | assertion | sweep reaches the sufficient region: 0 <= 0 |
| 257 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled` | PASS | FAIL | assertion | success region reached: 0 <= 0 |
| 258 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_TR1407_postOpGasLimit_sweep_via_entrypoint` | PASS | FAIL | revert/other | at/above the floor: executed and settled |
| 259 | `SuperPaymasterV55Adversarial.t.sol:SuperPaymasterV55AdversarialTest` | `test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33` | PASS | FAIL | revert/other | control: v2 token path sponsors |
| 260 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_I8_I9_I10_conservation` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x067567e50000000000000000000000000000000585f7cd5d3627c4d9674e9dbdb2c22a23 args=[1879485820647092361 |
| 261 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true; counterexample: calldata=0x0350e2360000000000000000000000000000000000000000000000000000000000000dcd args=[3533] |
| 262 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `testFuzz_G2_noOOGBand_direct_postOp` | PASS | FAIL | OOG / no-OOG band | no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete: 0x != 0x8890295d; counterexample: calldata=0xceba05ed0000000000000000000000000000000000000000000000000000000000002ecc0 |
| 263 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_fixed_seeds` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 264 | `SuperPaymasterV55Fuzz.t.sol:SuperPaymasterV55FuzzTest` | `test_G2_coverage_replay_floor_params` | PASS | FAIL | assertion | I8/B-1: op settled iff its settlement was not made to fail: false != true |
| 265 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_large_limits` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 266 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_user_call_reverts` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 267 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_sp_charge_covers_final_cost_worst_postOp_at_floor` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(0, "AA33 reverted", 0x) |
| 268 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_bundle_positions` | PASS | FAIL | assertion | C_WRAP bounds the overhead at every bundle position: 184136 > 5000 |
| 269 | `SuperPaymasterV55Gas.t.sol:SuperPaymasterV55GasTest` | `test_G_wrap_bound_canonical_entrypoint_single_ops` | PASS | FAIL | assertion | postOp really ran in every scenario: 3 != 4 |
| 270 | `SuperPaymasterV55GasParams.t.sol:SuperPaymasterV55GasParamsTest` | `test_settle_floor_keeps_no_oog_band` | PASS | FAIL | OOG / no-OOG band | SETTLE floor: no OOG band above the entry guard: 0x != 0x8890295d |
| 271 | `SuperPaymasterV55ParamRace.t.sol:SuperPaymasterV55ParamRaceTest` | `test_open_executor_param_change_mid_bundle_does_not_harm_admitted_ops` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 272 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_each_path_within_C_POSTOP` | PASS | FAIL | assertion | rule per path: BALANCE first-time user, cold lastTimestamp: 1750000000 < 2179790500 |
| 273 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_C_POSTOP_ge_W_postop_times_1_plus_m` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 274 | `SuperPaymasterV55PostOpBound.t.sol:SuperPaymasterV55PostOpBoundTest` | `test_rule_under_all_floor_params` | PASS | FAIL | assertion | probe postOp ran in every scenario: 2 != 3 |
| 275 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_rollback_to_5_5_0_settles_contexts_of_the_new_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 276 | `SuperPaymasterV55UpgradeRace.t.sol:SuperPaymasterV55UpgradeRaceTest` | `test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl` | PASS | FAIL | EntryPoint AA33 (paymaster validation reverted/OOG) | FailedOpWithRevert(1, "AA33 reverted", 0x) |
| 277 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `setUp` | — | SKIP |  |  |
| 278 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_DeletedBLSValidator_NoLongerImported` | PASS | — |  |  |
| 279 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_ConsistentAcrossSignerMaskOrderings` | PASS | — |  |  |
| 280 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_ReconstructsFromOnChainPKs_HappyPath` | PASS | — |  |  |
| 281 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsBelowThreshold` | PASS | — |  |  |
| 282 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsBitsBeyondMaxValidators` | PASS | — |  |  |
| 283 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsCallerSuppliedPkAgg_AbiGone` | PASS | — |  |  |
| 284 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsEmptySignerMask` | PASS | — |  |  |
| 285 | `BLSAggregator_PkAggReconstruct.t.sol:BLSAggregatorPkAggReconstructTest` | `test_Verify_RejectsForgedPkAgg_BySlotNotRegistered` | PASS | — |  |  |

### 1.8.6 amsterdam (old-sweep engine; regenerated) vs nightly amsterdam: 0 tests differ (1694 vs 1694 result lines)

| # | suite | test | 1.8.6 amsterdam (old-sweep engine; regenerated) | nightly amsterdam | class | failure reason |
|---|---|---|---|---|---|---|

### 1.8.6 prague (old-sweep engine; regenerated) vs nightly prague: 0 tests differ (1694 vs 1694 result lines)

| # | suite | test | 1.8.6 prague (old-sweep engine; regenerated) | nightly prague | class | failure reason |
|---|---|---|---|---|---|---|
