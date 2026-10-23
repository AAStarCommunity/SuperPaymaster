| test | rows (old / new) | identical | differing | only old | only new |
|---|---|---|---|---|---|
| control_original_fixture_test_B3_min_paymasterVerificationGasLimit_amsterdam.log | — / 2 | (no R-AMS-2a log: new test) | | | |
| test_B1_amsterdam.log | 199 / 199 | 119 | 80 | 0 | 0 |
| test_B2_amsterdam.log | 18 / 18 | 9 | 9 | 0 | 0 |
| test_B3_TR1409_amsterdam.log | 6 / 6 | 6 | 0 | 0 | 0 |
| test_B3_min_callGasLimit_amsterdam.log | 3 / 3 | 0 | 3 | 0 | 0 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | 2 / 2 | 0 | 2 | 0 | 0 |
| test_B3_min_postOp_amsterdam.log | 12 / 12 | 9 | 3 | 0 | 0 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | 2 / 2 | 0 | 2 | 0 | 0 |
| test_B4_amsterdam.log | 34 / 34 | 14 | 20 | 0 | 0 |
| test_B4b_amsterdam.log | — / 8 | (no R-AMS-2a log: new test) | | | |
| test_B5_amsterdam.log | 60 / 60 | 42 | 18 | 0 | 0 |
| test_B6_amsterdam.log | 49 / 49 | 31 | 18 | 0 | 0 |
| test_B7_amsterdam.log | 15 / 15 | 6 | 9 | 0 | 0 |
| test_B8_amsterdam.log | 144 / 144 | 96 | 48 | 0 | 0 |
| test_C_wrap_amsterdam.log | 8 / 8 | 8 | 0 | 0 | 0 |

keys identical: 340; keys differing or missing: 212

| test | key | R-AMS-2a (recompiled by forge nightly, prague) | rc.4 artifact bytes |
|---|---|---|---|
| test_B1_amsterdam.log | `B1.balance_first_op.actualGasUsed` | 1340281 | 1339728 |
| test_B1_amsterdam.log | `B1.balance_first_op.actualGasCost_wei` | 1340281000000000 | 1339728000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.spEpDepositDelta_wei` | 1340281000000000 | 1339728000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.charge_aPNTs` | 149504520000000000000 | 149456340000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.need_aPNTs(full cost at snapshot)` | 147430910000000000000 | 147370080000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.charge_minus_need_aPNTs` | 2073610000000000000 | 2086260000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.userBurn_xPNTs` | 149504520000000000000 | 149456340000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.testFrameGas_handleOps` | 1429226 | 1429516 |
| test_B1_amsterdam.log | `B1.balance_second_op.actualGasUsed` | 771782 | 771229 |
| test_B1_amsterdam.log | `B1.balance_second_op.actualGasCost_wei` | 771782000000000 | 771229000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.spEpDepositDelta_wei` | 771782000000000 | 771229000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.charge_aPNTs` | 99831710000000000000 | 99783530000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.need_aPNTs(full cost at snapshot)` | 84896020000000000000 | 84835190000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.charge_minus_need_aPNTs` | 14935690000000000000 | 14948340000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.userBurn_xPNTs` | 99831710000000000000 | 99783530000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.testFrameGas_handleOps` | 353534 | 353824 |
| test_B1_amsterdam.log | `B1.credit_first_op.actualGasUsed` | 1227013 | 1226508 |
| test_B1_amsterdam.log | `B1.credit_first_op.actualGasCost_wei` | 1227013000000000 | 1226508000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.spEpDepositDelta_wei` | 1227013000000000 | 1226508000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.charge_aPNTs` | 126943960000000000000 | 126894020000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.need_aPNTs(full cost at snapshot)` | 134971430000000000000 | 134915880000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.charge_minus_need_aPNTs` | -8027470000000000000 | -8021860000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.userDebtDelta_xPNTs` | 126943960000000000000 | 126894020000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.testFrameGas_handleOps` | 1326280 | 1326624 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.actualGasUsed` | 1289479 | 1288926 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.actualGasCost_wei` | 1289479000000000 | 1288926000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.spEpDepositDelta_wei` | 1289479000000000 | 1288926000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.charge_aPNTs` | 144454530000000000000 | 144406240000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.need_aPNTs(full cost at snapshot)` | 141842690000000000000 | 141781860000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.charge_minus_need_aPNTs` | 2611840000000000000 | 2624380000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.userBurn_xPNTs` | 144454530000000000000 | 144406240000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.testFrameGas_handleOps` | 1478668 | 1479172 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.actualGasUsed` | 1441503 | 1440891 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.actualGasCost_wei` | 1441503000000000 | 1440891000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.spEpDepositDelta_wei` | 1441503000000000 | 1440891000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.charge_aPNTs` | 161873250000000000000 | 161817810000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.need_aPNTs(full cost at snapshot)` | 158565330000000000000 | 158498010000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.charge_minus_need_aPNTs` | 3307920000000000000 | 3319800000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.userBurn_xPNTs` | 161873250000000000000 | 161817810000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.testFrameGas_handleOps` | 1542151 | 1542661 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.actualGasUsed` | 1540675 | 1540063 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.actualGasCost_wei` | 1540675000000000 | 1540063000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.spEpDepositDelta_wei` | 1540675000000000 | 1540063000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.charge_aPNTs` | 173994260000000000000 | 173938820000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.need_aPNTs(full cost at snapshot)` | 169474250000000000000 | 169406930000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.charge_minus_need_aPNTs` | 4520010000000000000 | 4531890000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.userBurn_xPNTs` | 173994260000000000000 | 173938820000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.testFrameGas_handleOps` | 1652431 | 1652940 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.actualGasUsed` | 1639847 | 1639235 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.actualGasCost_wei` | 1639847000000000 | 1639235000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.spEpDepositDelta_wei` | 1639847000000000 | 1639235000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.charge_aPNTs` | 186115270000000000000 | 186059830000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.need_aPNTs(full cost at snapshot)` | 180383170000000000000 | 180315850000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.charge_minus_need_aPNTs` | 5732100000000000000 | 5743980000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.userBurn_xPNTs` | 186115270000000000000 | 186059830000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.testFrameGas_handleOps` | 1762711 | 1763220 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.actualGasUsed` | 1328236 | 1327671 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.actualGasCost_wei` | 1328236000000000 | 1327671000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.spEpDepositDelta_wei` | 1328236000000000 | 1327671000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.charge_aPNTs` | 139312690000000000000 | 139255490000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.need_aPNTs(full cost at snapshot)` | 146105960000000000000 | 146043810000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.charge_minus_need_aPNTs` | -6793270000000000000 | -6788320000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.userDebtDelta_xPNTs` | 139312690000000000000 | 139255490000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.testFrameGas_handleOps` | 1439354 | 1439918 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.actualGasUsed` | 1427408 | 1426843 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.actualGasCost_wei` | 1427408000000000 | 1426843000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.spEpDepositDelta_wei` | 1427408000000000 | 1426843000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.charge_aPNTs` | 151433700000000000000 | 151376500000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.need_aPNTs(full cost at snapshot)` | 157014880000000000000 | 156952730000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.charge_minus_need_aPNTs` | -5581180000000000000 | -5576230000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.userDebtDelta_xPNTs` | 151433700000000000000 | 151376500000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.testFrameGas_handleOps` | 1549628 | 1550192 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.actualGasUsed` | 1526580 | 1526015 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.actualGasCost_wei` | 1526580000000000 | 1526015000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.spEpDepositDelta_wei` | 1526580000000000 | 1526015000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.charge_aPNTs` | 163554710000000000000 | 163497510000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.need_aPNTs(full cost at snapshot)` | 167923800000000000000 | 167861650000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.charge_minus_need_aPNTs` | -4369090000000000000 | -4364140000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.userDebtDelta_xPNTs` | 163554710000000000000 | 163497510000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.testFrameGas_handleOps` | 1659903 | 1660466 |
| test_B2_amsterdam.log | `B2.balance_first_op.F_real` | 1240281 | 1239728 |
| test_B2_amsterdam.log | `B2.balance_first_op.F_postOpMocked` | 1080770 | 1080332 |
| test_B2_amsterdam.log | `B2.balance_first_op.W_postop_EP(=(F_real-F_mocked)*10/9)` | 177234 | 177106 |
| test_B2_amsterdam.log | `B2.credit_first_op.F_real` | 1127013 | 1126508 |
| test_B2_amsterdam.log | `B2.credit_first_op.F_postOpMocked` | 875674 | 875220 |
| test_B2_amsterdam.log | `B2.credit_first_op.W_postop_EP(=(F_real-F_mocked)*10/9)` | 279265 | 279208 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.F_real` | 1541503 | 1540891 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.F_postOpMocked` | 1381992 | 1381495 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.W_postop_EP(=(F_real-F_mocked)*10/9)` | 177234 | 177106 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_0_fresh_slots` | 1842 | 1776 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_1_fresh_slots` | 115475 | 115408 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_2_fresh_slots` | 229192 | 229125 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | `B3.min_pmVerificationGasLimit.balance_first_op` | 820305 | 819940 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | `B3.min_pmVerificationGasLimit.credit_first_op` | 611954 | 611572 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.balance_first_op` | 365325 | 365207 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.credit_first_op` | 369624 | 369581 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.balance_first_op_user_writes_1` | 365325 | 365207 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | `B3.min_verificationGasLimit.deployed_SimpleAccount` | 119668 | 119590 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | `B3.min_verificationGasLimit.initCode_deploy_SimpleAccount` | 801247 | 817922 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_160000.min_settling_call_gas` | 365325 | 365207 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_160000.min_call_gas_passing_guard` | 164543 | 164500 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_160000.oog_band_width(gOk-gGuard,0=none)` | 200782 | 200707 |
| test_B4_amsterdam.log | `B4.balance_first_op.derived_min_SETTLE_no_band` | 360782 | 360707 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_361000.min_settling_call_gas` | 368733 | 368691 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_361000.min_call_gas_passing_guard` | 368733 | 368691 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_360000.min_settling_call_gas` | 367717 | 367675 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_360000.min_call_gas_passing_guard` | 367717 | 367675 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_155000.min_settling_call_gas` | 365325 | 365207 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_155000.min_call_gas_passing_guard` | 159463 | 159421 |
| test_B4_amsterdam.log | `B4.balance_first_op.SETTLE_155000.oog_band_width(gOk-gGuard,0=none)` | 205862 | 205786 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_160000.min_settling_call_gas` | 369624 | 369581 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_160000.min_call_gas_passing_guard` | 164543 | 164500 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_366000.min_settling_call_gas` | 373813 | 373770 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_366000.min_call_gas_passing_guard` | 373813 | 373770 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_365000.min_settling_call_gas` | 372797 | 372754 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_365000.min_call_gas_passing_guard` | 372797 | 372754 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_155000.min_settling_call_gas` | 369624 | 369581 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_155000.min_call_gas_passing_guard` | 159463 | 159421 |
| test_B4_amsterdam.log | `B4.credit_first_op.SETTLE_155000.oog_band_width(gOk-gGuard,0=none)` | 210161 | 210160 |
| test_B5_amsterdam.log | `B5.MIN_200000_SETTLE_160000.balance.need` | 141362210000000000000 | 141314030000000000000 |
| test_B5_amsterdam.log | `B5.MIN_200000_SETTLE_160000.credit.need` | 106050450000000000000 | 106000510000000000000 |
| test_B5_amsterdam.log | `B5.MIN_300000_SETTLE_280000.balance.need` | 151986560000000000000 | 151938270000000000000 |
| test_B5_amsterdam.log | `B5.MIN_300000_SETTLE_280000.credit.need` | 116894800000000000000 | 116844750000000000000 |
| test_B5_amsterdam.log | `B5.MIN_350000_SETTLE_330000.balance.need` | 128306640000000000000 | 128258240000000000000 |
| test_B5_amsterdam.log | `B5.MIN_350000_SETTLE_330000.credit.need` | 93214880000000000000 | 93164720000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.balance.charge` | 167433530000000000000 | 167385350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.balance.need` | 140609920000000000000 | 140549090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.credit.charge` | 132341770000000000000 | 132291830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.credit.need` | 94053080000000000000 | 93997530000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.balance.charge` | 173483530000000000000 | 173435350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.balance.need` | 141159920000000000000 | 141099090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.credit.charge` | 138391770000000000000 | 138341830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.credit.need` | 94603080000000000000 | 94547530000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.balance.charge` | 179533530000000000000 | 179485350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.balance.need` | 141709920000000000000 | 141649090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.credit.charge` | 144441770000000000000 | 144391830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.credit.need` | 95153080000000000000 | 95097530000000000000 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.actualGasUsed` | 1333615 | 1333085 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.actualGasCost_wei` | 1333615000000000 | 1333085000000000 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.spEpDepositDelta_wei` | 1333615000000000 | 1333085000000000 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.need_aPNTs(full cost at snapshot)` | 146697650000000000000 | 146639350000000000000 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.charge_minus_need_aPNTs` | -146697650000000000000 | -146639350000000000000 |
| test_B6_amsterdam.log | `B6.I8_settle_failure.testFrameGas_handleOps` | 1435752 | 1436352 |
| test_B6_amsterdam.log | `B6.releaseStaleLock.gasTotalUsed` | 86494 | 86348 |
| test_B6_amsterdam.log | `B6.releaseStaleLock.gasRefunded` | 17298 | 17269 |
| test_B6_amsterdam.log | `B6.releaseStaleSponsorship.gasTotalUsed` | 48682 | 48615 |
| test_B6_amsterdam.log | `B6.releaseStaleSponsorship.gasRefunded` | 9736 | 9723 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.actualGasUsed` | 1130508 | 1130021 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.actualGasCost_wei` | 1130508000000000 | 1130021000000000 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.spEpDepositDelta_wei` | 1130508000000000 | 1130021000000000 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.need_aPNTs(full cost at snapshot)` | 124355880000000000000 | 124302310000000000000 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.charge_minus_need_aPNTs` | -124355880000000000000 | -124302310000000000000 |
| test_B6_amsterdam.log | `B6.I8_credit_settle_failure.testFrameGas_handleOps` | 1229434 | 1229800 |
| test_B6_amsterdam.log | `B6.releaseStaleCredit.gasTotalUsed` | 60858 | 60792 |
| test_B6_amsterdam.log | `B6.releaseStaleSponsorship(credit).gasTotalUsed` | 48682 | 48615 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.actualGasUsed(PVG=0)` | 1290281 | 1289728 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.handleOps_frame_gas` | 1240725 | 1241015 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 49556 | 48713 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.actualGasUsed(PVG=0)` | 1391503 | 1390891 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.handleOps_frame_gas` | 1353383 | 1353894 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 38120 | 36997 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.actualGasUsed(PVG=0)` | 1490675 | 1490063 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.handleOps_frame_gas` | 1463624 | 1464134 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 27051 | 25929 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_first_op.charge_minus_need_aPNTs` | -141141220000000000000 | -141093040000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_first_op.actualGasUsed` | 1283102 | 1282664 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_writes_2.charge_minus_need_aPNTs` | -131277080000000000000 | -131222410000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_writes_2.actualGasUsed` | 1193428 | 1192931 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_first_op.charge_minus_need_aPNTs` | -106049460000000000000 | -105999520000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_first_op.actualGasUsed` | 964086 | 963632 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_call_reverts.charge_minus_need_aPNTs` | -123095390000000000000 | -123047100000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_call_reverts.actualGasUsed` | 1119049 | 1118610 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | -120382240000000000000 | -120327570000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 1094384 | 1093887 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | -97821680000000000000 | -97765250000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 889288 | 888775 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.charge_minus_need_aPNTs` | 19783610000000000000 | 19796260000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.actualGasUsed` | 1276772 | 1276219 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.charge_minus_need_aPNTs` | 43796170000000000000 | 43808050000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.actualGasUsed` | 1167190 | 1166578 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_first_op.charge_minus_need_aPNTs` | 31248690000000000000 | 31254300000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_first_op.actualGasUsed` | 853528 | 853023 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_call_reverts.charge_minus_need_aPNTs` | 32193920000000000000 | 32206460000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_call_reverts.actualGasUsed` | 1004122 | 1003569 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 42584080000000000000 | 42595960000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 980018 | 979406 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 32482890000000000000 | 32487840000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 866751 | 866186 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_first_op.charge_minus_need_aPNTs` | 20223610000000000000 | 20236260000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_first_op.actualGasUsed` | 1282272 | 1281719 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_writes_2.charge_minus_need_aPNTs` | 44236170000000000000 | 44248050000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_writes_2.actualGasUsed` | 1172690 | 1172078 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_first_op.charge_minus_need_aPNTs` | 31688690000000000000 | 31694300000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_first_op.actualGasUsed` | 859028 | 858523 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_call_reverts.charge_minus_need_aPNTs` | 32633920000000000000 | 32646460000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_call_reverts.actualGasUsed` | 1009622 | 1009069 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 43024080000000000000 | 43035960000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 985518 | 984906 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 32922890000000000000 | 32927840000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 872251 | 871686 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_first_op.charge_minus_need_aPNTs` | 15823610000000000000 | 15836260000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_first_op.actualGasUsed` | 1282272 | 1281719 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_writes_2.charge_minus_need_aPNTs` | 39836170000000000000 | 39848050000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_writes_2.actualGasUsed` | 1172690 | 1172078 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_first_op.charge_minus_need_aPNTs` | 27288690000000000000 | 27294300000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_first_op.actualGasUsed` | 859028 | 858523 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_call_reverts.charge_minus_need_aPNTs` | 28233920000000000000 | 28246460000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_call_reverts.actualGasUsed` | 1009622 | 1009069 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 38624080000000000000 | 38635960000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 985518 | 984906 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 28522890000000000000 | 28527840000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 872251 | 871686 |
