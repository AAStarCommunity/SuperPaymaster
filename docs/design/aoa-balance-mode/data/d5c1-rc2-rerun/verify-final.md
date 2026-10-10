mandatory suite sha256 `d61dd46ef91917c352b66950a16e84e978f86efdadcd68ebe793e68700c2e0eb`; expectations `script/halmos/d5c1-expectations.json` sha256 `e02667aeedb755e86992028f48a87e41aca5affd8c30c99dcc9d104de15004ce`; tree xpnts src `f81c71d5f61e846f` bytecode `d13cd8269b3350a5`, apnts src `702a7e293cc12242`

| 类别 | 项 | 期望 | 实际 | 判定 |
|---|---|---|---|---|
| tree | out/ [xpnts] | the build of the current sources (metadata keccak256) | fresh | OK |
| tree | out/ [apnts] | the build of the current sources (metadata keccak256) | fresh | OK |
| suite | logs:cap1.log | == mandatory suite | equal | OK |
| suite | logs:cap1-witness.log | == mandatory suite | equal | OK |
| suite | logs:rate-base.log | == mandatory suite | equal | OK |
| suite | logs:i4b-base.log | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2RateHalmosTest.check_RATE_step_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2RateHalmosTest.check_RATE_step_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3HalmosTest.check_A3_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3HalmosTest.check_A3_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3HalmosTest.check_A3_selfBurnDiscrepancy | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3MintNoDebtHalmosTest.check_A3_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I2HalmosTest.check_I2_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I2HalmosTest.check_I2_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I2MintNoDebtHalmosTest.check_I2_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I4BHalmosTest.check_I4B_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I4BHalmosTest.check_I4B_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I4BMintNoDebtHalmosTest.check_I4B_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6HalmosTest.check_I6_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6HalmosTest.check_I6_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6HalmosTest.check_I6J_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6HalmosTest.check_I6J_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6MintNoDebtHalmosTest.check_I6_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I6MintNoDebtHalmosTest.check_I6J_extAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2I2NoRHalmosTest.check_I2_coreAbi | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessHalmosTest.check_witness_I2_spRenewIncrements | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessHalmosTest.check_witness_I4B_outgoingWithLock | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessHalmosTest.check_witness_I6_reservationAdmitted | == mandatory suite | equal | OK |
| suite | partitioned:XPNTsV2WitnessHalmosTest.check_witness_I6_debtGrows | == mandatory suite | equal | OK |
| suite | partitioned:MintRepayLemmaHalmosTest.check_LEMMA_M_repayNeverExceedsMint | == mandatory suite | equal | OK |
| suite | partitioned:MintRepayLemmaHalmosTest.check_LEMMA_M1_floorDivTimesDivisor | == mandatory suite | equal | OK |
| suite | partitioned:MintRepayLemmaHalmosTest.check_LEMMA_M2_monotoneProduct | == mandatory suite | equal | OK |
| suite | partitioned:MintRepayLemmaHalmosTest.check_LEMMA_M3_ceilDivByConstant | == mandatory suite | equal | OK |
| suite | mutations:M-CAP1 | == mandatory suite | equal | OK |
| suite | mutations:M-A3 | == mandatory suite | equal | OK |
| suite | mutations:M-A3TF | == mandatory suite | equal | OK |
| suite | mutations:M-A3BF | == mandatory suite | equal | OK |
| suite | mutations:M-I2 | == mandatory suite | equal | OK |
| suite | mutations:M-I4B | == mandatory suite | equal | OK |
| suite | mutations:M-I6 | == mandatory suite | equal | OK |
| suite | mutations:M-F1 | == mandatory suite | equal | OK |
| suite | archives:artifact-parity.log | == mandatory suite | equal | OK |
| suite | archives:verify-selftest.log | == mandatory suite | equal | OK |
| suite | archives:forge-halmos-suite.log | == mandatory suite | equal | OK |
| suite | archives:cap1.log | == mandatory suite | equal | OK |
| suite | fuzz_liveness | == mandatory suite | equal | OK |
| binding | cap1.log | meta/argv/contract/binding/exit (apnts, cap1) | bound, fresh, dirty_src=0, argv and contract match | OK |
| log | cap1.log:check_CAP1_a_supplyIncreaseStaysUnderCap | PASS | PASS | OK |
| log | cap1.log:check_CAP1_b_onlyMinterMintIncreasesSupply | PASS | PASS | OK |
| log | cap1.log:check_CAP1_c_mintDoesNotMoveCap | PASS | PASS | OK |
| binding | cap1-witness.log | meta/argv/contract/binding/exit (apnts, cap1-fail) | bound, fresh, dirty_src=0, argv and contract match | OK |
| log | cap1-witness.log:check_witness_CAP1_supplyCanIncrease | FAIL | FAIL | OK |
| binding | rate-base.log | meta/argv/contract/binding/exit (xpnts, xp) | bound, fresh, dirty_src=0, argv and contract match | OK |
| log | rate-base.log:check_RATE_base_initialize | PASS | PASS | OK |
| log | rate-base.log:check_RATE_base_realFactory | PASS | PASS | OK |
| binding | i4b-base.log | meta/argv/contract/binding/exit (xpnts, xp) | bound, fresh, dirty_src=0, argv and contract match | OK |
| log | i4b-base.log:check_I4B_base_initialize | PASS | PASS | OK |
| log | i4b-base.log:check_I4B_base_realFactory | PASS | PASS | OK |
| partitioned | XPNTsV2RateHalmosTest.check_RATE_step_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2RateHalmosTest.check_RATE_step_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2RateHalmosTest.check_RATE_step_coreAbi | PASS | 14/15 PASS; BOUNDED burn-9dc29fac | MISMATCH |
| partitioned | XPNTsV2RateHalmosTest.check_RATE_step_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2RateHalmosTest.check_RATE_step_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2RateHalmosTest.check_RATE_step_extAbi | PASS | PASS (44/44) | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2A3HalmosTest.check_A3_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_coreAbi | PASS (ceiling: settleLocked-7e48bbce,tryLockForGas-ec290731) | 14/15 PASS; DISCREPANCY-FAIL burn-9dc29fac | OK |
| discrepancy | XPNTsV2A3HalmosTest.check_A3_coreAbi:burn-9dc29fac | FAIL+cex (documented spec-vs-code discrepancy) | FAIL+cex — D-A3-2: spec 03 §2.3 A-3 rejects burn(address,uint256) for any current/historical SP caller; xPNTsTokenV2.sol:134 skips _spendV2 (and with it the firewall) when from == msg.sender, so an SP can burn its OWN balance. Reported, not weakened (replay: test_D5c1_DISCREPANCY_A3_2_spBurnsOwnBalance) | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2A3HalmosTest.check_A3_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_extAbi | PASS (ceiling: mint-40c10f19) | 43/44 PASS; BOUNDED mint-40c10f19 | OK |
| bounded | XPNTsV2A3HalmosTest.check_A3_extAbi:mint-40c10f19 | BOUNDED (allowed) | TIMEOUT — mint auto-repay non-linearity (lemma M); substitute: XPNTsV2A3MintNoDebtHalmosTest (debts = 0, symbolic) + MintRepayLemmaFuzzTest (debts > 0, 10,000 runs) + paper proof | OK |
| partitioned | XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_selfBurnDiscrepancy: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3HalmosTest.check_A3_selfBurnDiscrepancy | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3HalmosTest.check_A3_selfBurnDiscrepancy | FAIL | FAIL+cex in burn-9dc29fac | OK |
| partitioned | XPNTsV2A3MintNoDebtHalmosTest.check_A3_extAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3MintNoDebtHalmosTest.check_A3_extAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3MintNoDebtHalmosTest.check_A3_extAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound | PASS (ceiling: settleLocked-7e48bbce) | 0/1 PASS; BOUNDED settleLocked-7e48bbce | OK |
| bounded | XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound:settleLocked-7e48bbce | BOUNDED (allowed) | TIMEOUT-WALL — non-linear exact ceil bound (mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_settleLocked asserts the A3x bitmask (10,000 runs) | OK |
| partitioned | XPNTsV2I2HalmosTest.check_I2_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2I2HalmosTest.check_I2_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I2HalmosTest.check_I2_coreAbi | PASS (ceiling: burn-9dc29fac,settleLocked-7e48bbce,transferFrom-23b872dd,tryLockForGas-ec290731) | 11/15 PASS; BOUNDED burn-9dc29fac,settleLocked-7e48bbce,transferFrom-23b872dd,tryLockForGas-ec290731 | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_coreAbi:burn-9dc29fac | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered burn(from): mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_burnFrom (10,000 runs) + boundary cases | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_coreAbi:settleLocked-7e48bbce | BOUNDED (allowed) | TIMEOUT-WALL — solver / wall cap (mulDiv in settle); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_settleLocked (10,000 runs) + boundary cases | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_coreAbi:transferFrom-23b872dd | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered pull: mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_transferFrom (10,000 runs) + boundary cases | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_coreAbi:tryLockForGas-ec290731 | BOUNDED (allowed) | TIMEOUT-WALL — solver / wall cap (mulDiv in the lock path); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_tryLockForGas (10,000 runs) + boundary cases | OK |
| partitioned | XPNTsV2I2HalmosTest.check_I2_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2I2HalmosTest.check_I2_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I2HalmosTest.check_I2_extAbi | PASS (ceiling: mint-40c10f19,transferFrom-23b872dd) | 42/44 PASS; BOUNDED mint-40c10f19,transferFrom-23b872dd | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_extAbi:mint-40c10f19 | BOUNDED (allowed) | TIMEOUT-WALL — mint auto-repay non-linearity (lemma M); substitute: XPNTsV2I2MintNoDebtHalmosTest + MintRepayLemmaFuzzTest + paper proof | OK |
| bounded | XPNTsV2I2HalmosTest.check_I2_extAbi:transferFrom-23b872dd | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered pull: mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_transferFrom (10,000 runs) + boundary cases | OK |
| partitioned | XPNTsV2I2MintNoDebtHalmosTest.check_I2_extAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2I2MintNoDebtHalmosTest.check_I2_extAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I2MintNoDebtHalmosTest.check_I2_extAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2I4BHalmosTest.check_I4B_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2I4BHalmosTest.check_I4B_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I4BHalmosTest.check_I4B_coreAbi | PASS (ceiling: burn-9dc29fac,settleLocked-7e48bbce,transferFrom-23b872dd,tryLockForGas-ec290731) | 11/15 PASS; BOUNDED burn-9dc29fac,settleLocked-7e48bbce,transferFrom-23b872dd,tryLockForGas-ec290731 | OK |
| bounded | XPNTsV2I4BHalmosTest.check_I4B_coreAbi:burn-9dc29fac | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered burn(from): mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_burnFrom asserts the I4-B bitmask (10,000 runs) | OK |
| bounded | XPNTsV2I4BHalmosTest.check_I4B_coreAbi:settleLocked-7e48bbce | BOUNDED (allowed) | TIMEOUT-WALL — solver / wall cap (mulDiv in settle); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_settleLocked asserts the I4-B bitmask (10,000 runs) | OK |
| bounded | XPNTsV2I4BHalmosTest.check_I4B_coreAbi:transferFrom-23b872dd | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered pull: mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_transferFrom asserts the I4-B bitmask (10,000 runs) | OK |
| bounded | XPNTsV2I4BHalmosTest.check_I4B_coreAbi:tryLockForGas-ec290731 | BOUNDED (allowed) | TIMEOUT-WALL — solver / wall cap (mulDiv in the lock path); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_tryLockForGas asserts the I4-B bitmask (10,000 runs) | OK |
| partitioned | XPNTsV2I4BHalmosTest.check_I4B_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2I4BHalmosTest.check_I4B_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I4BHalmosTest.check_I4B_extAbi | PASS (ceiling: mint-40c10f19,transferFrom-23b872dd) | 43/44 PASS; BOUNDED transferFrom-23b872dd | OK |
| bounded | XPNTsV2I4BHalmosTest.check_I4B_extAbi:transferFrom-23b872dd | BOUNDED (allowed) | TIMEOUT-WALL — wall cap (metered pull: mulDiv); substitute: D5c1BoundedFuzzTest.testFuzz_D5c1_I2_transferFrom asserts the I4-B bitmask (10,000 runs) | OK |
| partitioned | XPNTsV2I4BMintNoDebtHalmosTest.check_I4B_extAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2I4BMintNoDebtHalmosTest.check_I4B_extAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I4BMintNoDebtHalmosTest.check_I4B_extAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2I6HalmosTest.check_I6_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2I6HalmosTest.check_I6_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6HalmosTest.check_I6_coreAbi | PASS | 13/15 PASS; BOUNDED burn-9dc29fac,transferFrom-23b872dd | MISMATCH |
| partitioned | XPNTsV2I6HalmosTest.check_I6_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2I6HalmosTest.check_I6_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6HalmosTest.check_I6_extAbi | PASS (ceiling: mint-40c10f19) | 43/44 PASS; BOUNDED transferFrom-23b872dd | MISMATCH |
| partitioned | XPNTsV2I6HalmosTest.check_I6J_coreAbi: partition set | exactly 15 (from current ABI) | equal | OK |
| binding | XPNTsV2I6HalmosTest.check_I6J_coreAbi | 15 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6HalmosTest.check_I6J_coreAbi | PASS | 13/15 PASS; BOUNDED burn-9dc29fac,transferFrom-23b872dd | MISMATCH |
| partitioned | XPNTsV2I6HalmosTest.check_I6J_extAbi: partition set | exactly 44 (from current ABI) | equal | OK |
| binding | XPNTsV2I6HalmosTest.check_I6J_extAbi | 44 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6HalmosTest.check_I6J_extAbi | PASS (ceiling: mint-40c10f19) | 43/44 PASS; BOUNDED transferFrom-23b872dd | MISMATCH |
| partitioned | XPNTsV2I6MintNoDebtHalmosTest.check_I6_extAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2I6MintNoDebtHalmosTest.check_I6_extAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6MintNoDebtHalmosTest.check_I6_extAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2I6MintNoDebtHalmosTest.check_I6J_extAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2I6MintNoDebtHalmosTest.check_I6J_extAbi | 1 logs: meta/argv/contract/binding/exit (xp) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I6MintNoDebtHalmosTest.check_I6J_extAbi | PASS | PASS (1/1) | OK |
| partitioned | XPNTsV2I2NoRHalmosTest.check_I2_coreAbi: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2I2NoRHalmosTest.check_I2_coreAbi | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2I2NoRHalmosTest.check_I2_coreAbi | FAIL | BOUNDED tryLockForGas-ec290731 | MISMATCH |
| partitioned | XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim | FAIL | FAIL+cex in settleLocked-7e48bbce | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I2_spRenewIncrements: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessHalmosTest.check_witness_I2_spRenewIncrements | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I2_spRenewIncrements | FAIL | FAIL+cex in tryLockForGas-ec290731 | OK |
| partitioned | XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull | FAIL | FAIL+cex in transferFrom-23b872dd | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull | FAIL | FAIL+cex in transferFrom-23b872dd | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I4B_outgoingWithLock: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessHalmosTest.check_witness_I4B_outgoingWithLock | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I4B_outgoingWithLock | FAIL | FAIL+cex in transfer-a9059cbb | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I6_reservationAdmitted: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessHalmosTest.check_witness_I6_reservationAdmitted | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I6_reservationAdmitted | FAIL | FAIL+cex in tryReserveCredit-de9e4cae | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I6_debtGrows: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | XPNTsV2WitnessHalmosTest.check_witness_I6_debtGrows | 1 logs: meta/argv/contract/binding/exit (xp-fail) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | XPNTsV2WitnessHalmosTest.check_witness_I6_debtGrows | FAIL | FAIL+cex in settleCredit-1baf4408 | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M_repayNeverExceedsMint: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | MintRepayLemmaHalmosTest.check_LEMMA_M_repayNeverExceedsMint | 1 logs: meta/argv/contract/binding/exit (lemma) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M_repayNeverExceedsMint | PASS (ceiling: OTHER) | 0/1 PASS; BOUNDED OTHER | OK |
| bounded | MintRepayLemmaHalmosTest.check_LEMMA_M_repayNeverExceedsMint:OTHER | BOUNDED (allowed) | TIMEOUT-WALL — 256-bit division / product beyond the solver (540 s assertion timeout); substitute: paper proof (D5c-1-halmos.md §2.5) + MintRepayLemmaFuzzTest (10,000 runs) | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M1_floorDivTimesDivisor: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | MintRepayLemmaHalmosTest.check_LEMMA_M1_floorDivTimesDivisor | 1 logs: meta/argv/contract/binding/exit (lemma) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M1_floorDivTimesDivisor | PASS (ceiling: OTHER) | 0/1 PASS; BOUNDED OTHER | OK |
| bounded | MintRepayLemmaHalmosTest.check_LEMMA_M1_floorDivTimesDivisor:OTHER | BOUNDED (allowed) | TIMEOUT-WALL — 256-bit division / product beyond the solver (540 s assertion timeout); substitute: paper proof (D5c-1-halmos.md §2.5) + MintRepayLemmaFuzzTest (10,000 runs) | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M2_monotoneProduct: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | MintRepayLemmaHalmosTest.check_LEMMA_M2_monotoneProduct | 1 logs: meta/argv/contract/binding/exit (lemma) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M2_monotoneProduct | PASS (ceiling: OTHER) | 0/1 PASS; BOUNDED OTHER | OK |
| bounded | MintRepayLemmaHalmosTest.check_LEMMA_M2_monotoneProduct:OTHER | BOUNDED (allowed) | TIMEOUT — 256-bit division / product beyond the solver (540 s assertion timeout); substitute: paper proof (D5c-1-halmos.md §2.5) + MintRepayLemmaFuzzTest (10,000 runs) | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M3_ceilDivByConstant: partition set | exactly 1 (from current ABI) | equal | OK |
| binding | MintRepayLemmaHalmosTest.check_LEMMA_M3_ceilDivByConstant | 1 logs: meta/argv/contract/binding/exit (lemma) | all bound, fresh, dirty_src=0, argv/label/selector match | OK |
| partitioned | MintRepayLemmaHalmosTest.check_LEMMA_M3_ceilDivByConstant | PASS (ceiling: OTHER) | 0/1 PASS; BOUNDED OTHER | OK |
| bounded | MintRepayLemmaHalmosTest.check_LEMMA_M3_ceilDivByConstant:OTHER | BOUNDED (allowed) | TIMEOUT — 256-bit division / product beyond the solver (540 s assertion timeout); substitute: paper proof (D5c-1-halmos.md §2.5) + MintRepayLemmaFuzzTest (10,000 runs) | OK |
| mutation | M-CAP1 halmos check_CAP1_a_supplyIncreaseStaysUnderCap | FAIL+cex | FAIL | OK |
| mutation | M-CAP1 scenario test_D5c1_CAP1_scenario_mintBeyondCapReverts | red (next call did not revert as expected) | next call did not revert as expected | OK |
| mutation | M-CAP1 binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-CAP1 restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-CAP1 source restored | pristine == reverted == current file | 07e1cf5b3d34 | OK |
| mutation | M-A3 halmos XPNTsV2A3HalmosTest.check_A3_extAbi:spPull-20992765 | exactly these parts, all FAIL+cex | red ['spPull-20992765'] | OK |
| mutation | M-A3 halmos XPNTsV2A3HalmosTest.check_A3_coreAbi:OTHER | exactly these parts, all FAIL+cex | red ['OTHER'] | OK |
| mutation | M-A3 scenario test_D5c1_A3_scenario_spCannotMoveUserTokens | red (28 != 0) | A-3 predicate bitmask on the SP pull attempt: 28 != 0 | OK |
| mutation | M-A3 binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-A3 restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-A3 source restored | pristine == reverted == current file | ed46ee6bc1c8 | OK |
| mutation | M-A3TF halmos XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi:transferFrom-23b872dd | exactly these parts, all FAIL+cex | red ['transferFrom-23b872dd'] | OK |
| mutation | M-A3TF halmos XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi:burn-9dc29fac | exactly these parts, still PASS (independence) | green ['burn-9dc29fac'] | OK |
| mutation | M-A3TF scenario test_D5c1_A3_scenario_spFirewallBits | red (A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 1 != 0) | A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 1 != 0 | OK |
| mutation | M-A3TF binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-A3TF restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-A3TF source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| mutation | M-A3BF halmos XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi:burn-9dc29fac | exactly these parts, all FAIL+cex | red ['burn-9dc29fac'] | OK |
| mutation | M-A3BF halmos XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi:transferFrom-23b872dd | exactly these parts, still PASS (independence) | green ['transferFrom-23b872dd'] | OK |
| mutation | M-A3BF scenario test_D5c1_A3_scenario_spFirewallBits | red (A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 2 != 0) | A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 2 != 0 | OK |
| mutation | M-A3BF binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-A3BF restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-A3BF source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| mutation | M-I2 halmos XPNTsV2I2HalmosTest.check_I2_coreAbi:tryLockForGas-ec290731 | exactly these parts, all FAIL+cex | red ['tryLockForGas-ec290731'] | OK |
| mutation | M-I2 scenario test_D5c1_I2_scenario_lockBeyondSpCapRejected | red (I2 predicate bitmask on the over-cap lock attempt: 32769 != 0) | I2 predicate bitmask on the over-cap lock attempt: 32769 != 0 | OK |
| mutation | M-I2 binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-I2 restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-I2 source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| mutation | M-I4B halmos XPNTsV2I4BHalmosTest.check_I4B_coreAbi:transfer-a9059cbb | exactly these parts, all FAIL+cex | red ['transfer-a9059cbb'] | OK |
| mutation | M-I4B scenario test_D5c1_I4B_scenario_transferBelowLockedRejected | red (I4-B predicate bitmask on the over-lock transfer: 1 != 0) | I4-B predicate bitmask on the over-lock transfer: 1 != 0 | OK |
| mutation | M-I4B binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-I4B restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-I4B source restored | pristine == reverted == current file | 20d1bbda5cc7 | OK |
| mutation | M-I6 halmos XPNTsV2I6HalmosTest.check_I6_coreAbi:tryReserveCredit-de9e4cae | exactly these parts, all FAIL+cex | red ['tryReserveCredit-de9e4cae'] | OK |
| mutation | M-I6 halmos XPNTsV2I6HalmosTest.check_I6J_coreAbi:tryReserveCredit-de9e4cae | exactly these parts, all FAIL+cex | red ['tryReserveCredit-de9e4cae'] | OK |
| mutation | M-I6 scenario test_D5c1_I6_scenario_reservationBoundedByRequestedCap | red (1 != 0) | I6 predicate bitmask on the over-request reservation: 1 != 0 | OK |
| mutation | M-I6 binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-I6 restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-I6 source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| mutation | M-F1 halmos check_RATE_base_initialize | FAIL+cex | FAIL | OK |
| mutation | M-F1 halmos check_RATE_base_realFactory | FAIL+cex | FAIL | OK |
| mutation | M-F1 scenario test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit | red (next call did not revert as expected) | next call did not revert as expected | OK |
| mutation | M-F1 binding (mutated) | logs bound to current src + diff, mutated harness build | ok | OK |
| mutation | M-F1 restored tree | src/lib/harness/bytecode == current | equal | OK |
| mutation | M-F1 source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| binding | fuzz-liveness/fuzz-bounded-partitions.log | bound to current tree (xpnts) | bound, fresh, dirty_src=0 | OK |
| fuzz | unmutated testFuzz_D5c1_I2_tryLockForGas | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | unmutated testFuzz_D5c1_I2_settleLocked | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | unmutated testFuzz_D5c1_I2_transferFrom | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | unmutated testFuzz_D5c1_I2_burnFrom | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | unmutated testFuzz_D5c1_I4B_mintWithDebt | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | unmutated testFuzz_D5c1_lemmaM_mintWithDebtNeverLowersBalance | PASS (>=10000 runs) | PASS runs=10000 | OK |
| fuzz | M-I2 reddens testFuzz_D5c1_I2_tryLockForGas | red | red | OK |
| fuzz | M-I2 binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-I2 restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-I2 source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| fuzz | M-PULL reddens testFuzz_D5c1_I2_transferFrom | red | red | OK |
| fuzz | M-PULL reddens testFuzz_D5c1_I2_burnFrom | red | red | OK |
| fuzz | M-PULL binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-PULL restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-PULL source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| fuzz | M-EXPL reddens testFuzz_D5c1_I2_transferFrom | red | red | OK |
| fuzz | M-EXPL reddens testFuzz_D5c1_I2_burnFrom | red | red | OK |
| fuzz | M-EXPL binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-EXPL restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-EXPL source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| fuzz | M-BURNALL reddens testFuzz_D5c1_I2_settleLocked | red | red | OK |
| fuzz | M-BURNALL binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-BURNALL restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-BURNALL source restored | pristine == reverted == current file | 6ddccb29160f | OK |
| fuzz | M-REPAY reddens testFuzz_D5c1_lemmaM_mintWithDebtNeverLowersBalance | red | red | OK |
| fuzz | M-REPAY binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-REPAY restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-REPAY source restored | pristine == reverted == current file | 20d1bbda5cc7 | OK |
| fuzz | M-REPAYLOCK reddens testFuzz_D5c1_I4B_mintWithDebt | red | red | OK |
| fuzz | M-REPAYLOCK binding (mutated) | log bound to current src + diff | ok | OK |
| fuzz | M-REPAYLOCK restored tree | src/lib/harness/bytecode == current | equal | OK |
| fuzz | M-REPAYLOCK source restored | pristine == reverted == current file | 20d1bbda5cc7 | OK |
| archive | artifact-parity.log | two passes RESULT: OK, bound to the current tree + harness build | 2/2 OK (after the Halmos-style build (forge build --ast --extra-output storageLayout metadata); after a plain forge build (the deployment build)) | OK |
| archive | verify-selftest.log | self-test of THESE scripts, all controls behave, count quoted in the report | final line None, ok-lines 56, FAIL-lines 1 | MISMATCH |
| archive | forge-halmos-suite.log | replay/layout/priming/boundary forge suite green, bound | green (32 tests), 11 named tests present | OK |
| archive | cap1.log numbers in D5c-1-halmos.md | paths/times quoted = the final log | doc lacks '(a) PASS，108 条路径，8.33 s'; doc lacks '(b) PASS，107 条路径，9.22 s'; doc lacks '(c) PASS，105 条路径，14.46 s' | MISMATCH |
