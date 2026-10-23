| test | rows (old / new) | identical | differing | only old | only new |
|---|---|---|---|---|---|
| test_B1_amsterdam.log | 199 / 199 | 116 | 83 | 0 | 0 |
| test_B2_amsterdam.log | 18 / 18 | 9 | 9 | 0 | 0 |
| test_B3_TR1409_amsterdam.log | 6 / 6 | 6 | 0 | 0 | 0 |
| test_B3_min_callGasLimit_amsterdam.log | 3 / 3 | 0 | 3 | 0 | 0 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | 2 / 2 | 0 | 2 | 0 | 0 |
| test_B3_min_postOp_amsterdam.log | 12 / 12 | 6 | 6 | 0 | 0 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | 2 / 2 | 0 | 2 | 0 | 0 |
| test_B5_amsterdam.log | 60 / 60 | 42 | 18 | 0 | 0 |
| test_B6_amsterdam.log | 49 / 49 | 49 | 0 | 0 | 0 |
| test_B7_amsterdam.log | 15 / 15 | 6 | 9 | 0 | 0 |
| test_B8_amsterdam.log | 144 / 144 | 92 | 52 | 0 | 0 |
| test_C_wrap_amsterdam.log | 8 / 8 | 4 | 4 | 0 | 0 |
| test_F2_matrix_amsterdam.log | — / 37 | (no R-AMS-2a log: new test) | | | |

keys identical: 330; keys differing or missing: 188

| test | key | rc.4 artifact bytes, --no-isolate | rc.4 artifact bytes, --isolate |
|---|---|---|---|
| test_B1_amsterdam.log | `B1.balance_first_op.actualGasUsed` | 1339728 | 1453728 |
| test_B1_amsterdam.log | `B1.balance_first_op.actualGasCost_wei` | 1339728000000000 | 1453728000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.spEpDepositDelta_wei` | 1339728000000000 | 1453728000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.charge_aPNTs` | 149456340000000000000 | 158630340000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.need_aPNTs(full cost at snapshot)` | 147370080000000000000 | 159910080000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.chargeCoversNeed(I9/G2)` | 1 | 0 |
| test_B1_amsterdam.log | `B1.balance_first_op.charge_minus_need_aPNTs` | 2086260000000000000 | -1279740000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.userBurn_xPNTs` | 149456340000000000000 | 158630340000000000000 |
| test_B1_amsterdam.log | `B1.balance_first_op.testFrameGas_handleOps` | 1429516 | 1572244 |
| test_B1_amsterdam.log | `B1.balance_second_op.actualGasUsed` | 771229 | 974029 |
| test_B1_amsterdam.log | `B1.balance_second_op.actualGasCost_wei` | 771229000000000 | 974029000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.spEpDepositDelta_wei` | 771229000000000 | 974029000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.charge_aPNTs` | 99783530000000000000 | 115557530000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.need_aPNTs(full cost at snapshot)` | 84835190000000000000 | 107143190000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.charge_minus_need_aPNTs` | 14948340000000000000 | 8414340000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.userBurn_xPNTs` | 99783530000000000000 | 115557530000000000000 |
| test_B1_amsterdam.log | `B1.balance_second_op.testFrameGas_handleOps` | 353824 | 605476 |
| test_B1_amsterdam.log | `B1.credit_first_op.actualGasUsed` | 1226508 | 1338508 |
| test_B1_amsterdam.log | `B1.credit_first_op.actualGasCost_wei` | 1226508000000000 | 1338508000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.spEpDepositDelta_wei` | 1226508000000000 | 1338508000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.charge_aPNTs` | 126894020000000000000 | 138026020000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.need_aPNTs(full cost at snapshot)` | 134915880000000000000 | 147235880000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.charge_minus_need_aPNTs` | -8021860000000000000 | -9209860000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.userDebtDelta_xPNTs` | 126894020000000000000 | 138026020000000000000 |
| test_B1_amsterdam.log | `B1.credit_first_op.testFrameGas_handleOps` | 1326624 | 1465164 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.actualGasUsed` | 1288926 | 1402966 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.actualGasCost_wei` | 1288926000000000 | 1402966000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.spEpDepositDelta_wei` | 1288926000000000 | 1402966000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.charge_aPNTs` | 144406240000000000000 | 153585190000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.need_aPNTs(full cost at snapshot)` | 141781860000000000000 | 154326260000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.chargeCoversNeed(I9/G2)` | 1 | 0 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.charge_minus_need_aPNTs` | 2624380000000000000 | -741070000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.userBurn_xPNTs` | 144406240000000000000 | 153585190000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_call_reverts.testFrameGas_handleOps` | 1479172 | 1623097 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.actualGasUsed` | 1440891 | 1557501 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.actualGasCost_wei` | 1440891000000000 | 1557501000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.spEpDepositDelta_wei` | 1440891000000000 | 1557501000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.charge_aPNTs` | 161817810000000000000 | 171310810000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.need_aPNTs(full cost at snapshot)` | 158498010000000000000 | 171325110000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.chargeCoversNeed(I9/G2)` | 1 | 0 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.charge_minus_need_aPNTs` | 3319800000000000000 | -14300000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.userBurn_xPNTs` | 161817810000000000000 | 171310810000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_1_fresh_slots.testFrameGas_handleOps` | 1542661 | 1689733 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.actualGasUsed` | 1540063 | 1656673 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.actualGasCost_wei` | 1540063000000000 | 1656673000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.spEpDepositDelta_wei` | 1540063000000000 | 1656673000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.charge_aPNTs` | 173938820000000000000 | 183431820000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.need_aPNTs(full cost at snapshot)` | 169406930000000000000 | 182234030000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.charge_minus_need_aPNTs` | 4531890000000000000 | 1197790000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.userBurn_xPNTs` | 173938820000000000000 | 183431820000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_2_fresh_slots.testFrameGas_handleOps` | 1652940 | 1800012 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.actualGasUsed` | 1639235 | 1755845 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.actualGasCost_wei` | 1639235000000000 | 1755845000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.spEpDepositDelta_wei` | 1639235000000000 | 1755845000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.charge_aPNTs` | 186059830000000000000 | 195552830000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.need_aPNTs(full cost at snapshot)` | 180315850000000000000 | 193142950000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.charge_minus_need_aPNTs` | 5743980000000000000 | 2409880000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.userBurn_xPNTs` | 186059830000000000000 | 195552830000000000000 |
| test_B1_amsterdam.log | `B1.balance_user_writes_3_fresh_slots.testFrameGas_handleOps` | 1763220 | 1910292 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.actualGasUsed` | 1327671 | 1442281 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.actualGasCost_wei` | 1327671000000000 | 1442281000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.spEpDepositDelta_wei` | 1327671000000000 | 1442281000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.charge_aPNTs` | 139255490000000000000 | 150706490000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.need_aPNTs(full cost at snapshot)` | 146043810000000000000 | 158650910000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.charge_minus_need_aPNTs` | -6788320000000000000 | -7944420000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.userDebtDelta_xPNTs` | 139255490000000000000 | 150706490000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_1_fresh_slots.testFrameGas_handleOps` | 1439918 | 1582790 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.actualGasUsed` | 1426843 | 1541453 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.actualGasCost_wei` | 1426843000000000 | 1541453000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.spEpDepositDelta_wei` | 1426843000000000 | 1541453000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.charge_aPNTs` | 151376500000000000000 | 162827500000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.need_aPNTs(full cost at snapshot)` | 156952730000000000000 | 169559830000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.charge_minus_need_aPNTs` | -5576230000000000000 | -6732330000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.userDebtDelta_xPNTs` | 151376500000000000000 | 162827500000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_2_fresh_slots.testFrameGas_handleOps` | 1550192 | 1693064 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.actualGasUsed` | 1526015 | 1640625 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.actualGasCost_wei` | 1526015000000000 | 1640625000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.spEpDepositDelta_wei` | 1526015000000000 | 1640625000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.charge_aPNTs` | 163497510000000000000 | 174948510000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.need_aPNTs(full cost at snapshot)` | 167861650000000000000 | 180468750000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.charge_minus_need_aPNTs` | -4364140000000000000 | -5520240000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.userDebtDelta_xPNTs` | 163497510000000000000 | 174948510000000000000 |
| test_B1_amsterdam.log | `B1.credit_user_writes_3_fresh_slots.testFrameGas_handleOps` | 1660466 | 1803338 |
| test_B2_amsterdam.log | `B2.balance_first_op.F_real` | 1239728 | 1353728 |
| test_B2_amsterdam.log | `B2.balance_first_op.F_postOpMocked` | 1080332 | 1163732 |
| test_B2_amsterdam.log | `B2.balance_first_op.W_postop_EP(=(F_real-F_mocked)*10/9)` | 177106 | 211106 |
| test_B2_amsterdam.log | `B2.credit_first_op.F_real` | 1126508 | 1238508 |
| test_B2_amsterdam.log | `B2.credit_first_op.F_postOpMocked` | 875220 | 976420 |
| test_B2_amsterdam.log | `B2.credit_first_op.W_postop_EP(=(F_real-F_mocked)*10/9)` | 279208 | 291208 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.F_real` | 1540891 | 1657501 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.F_postOpMocked` | 1381495 | 1467505 |
| test_B2_amsterdam.log | `B2.balance_first_op_user_writes_1.W_postop_EP(=(F_real-F_mocked)*10/9)` | 177106 | 211106 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_0_fresh_slots` | 1776 | 4715 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_1_fresh_slots` | 115408 | 118354 |
| test_B3_min_callGasLimit_amsterdam.log | `B3.min_callGasLimit.execute_writing_2_fresh_slots` | 229125 | 232071 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | `B3.min_pmVerificationGasLimit.balance_first_op` | 819940 | 882357 |
| test_B3_min_paymasterVerificationGasLimit_amsterdam.log | `B3.min_pmVerificationGasLimit.credit_first_op` | 611572 | 695045 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.balance_first_op` | 365207 | 398430 |
| test_B3_min_postOp_amsterdam.log | `B3.postOpGasLimit_EP.balance_first_op.non_guard_failures_in_[175k,min)_step2k` | 96 | 112 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.credit_first_op` | 369581 | 379739 |
| test_B3_min_postOp_amsterdam.log | `B3.postOpGasLimit_EP.credit_first_op.non_guard_failures_in_[175k,min)_step2k` | 98 | 103 |
| test_B3_min_postOp_amsterdam.log | `B3.min_postOpGasLimit_EP.balance_first_op_user_writes_1` | 365207 | 398430 |
| test_B3_min_postOp_amsterdam.log | `B3.postOpGasLimit_EP.balance_first_op_user_writes_1.non_guard_failures_in_[175k,min)_step2k` | 96 | 112 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | `B3.min_verificationGasLimit.deployed_SimpleAccount` | 119590 | 129390 |
| test_B3_min_verificationGasLimit_account_amsterdam.log | `B3.min_verificationGasLimit.initCode_deploy_SimpleAccount` | 817922 | 823722 |
| test_B5_amsterdam.log | `B5.MIN_200000_SETTLE_160000.balance.need` | 141314030000000000000 | 150488030000000000000 |
| test_B5_amsterdam.log | `B5.MIN_200000_SETTLE_160000.credit.need` | 106000510000000000000 | 119112510000000000000 |
| test_B5_amsterdam.log | `B5.MIN_300000_SETTLE_280000.balance.need` | 151938270000000000000 | 161332270000000000000 |
| test_B5_amsterdam.log | `B5.MIN_300000_SETTLE_280000.credit.need` | 116844750000000000000 | 129956750000000000000 |
| test_B5_amsterdam.log | `B5.MIN_350000_SETTLE_330000.balance.need` | 128258240000000000000 | 166754940000000000000 |
| test_B5_amsterdam.log | `B5.MIN_350000_SETTLE_330000.credit.need` | 93164720000000000000 | 135379420000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.balance.charge` | 167385350000000000000 | 176779350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.balance.need` | 140549090000000000000 | 153309090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.credit.charge` | 132291830000000000000 | 145403830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_400000_SETTLE_380000.credit.need` | 93997530000000000000 | 110475530000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.balance.charge` | 173435350000000000000 | 182829350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.balance.need` | 141099090000000000000 | 153859090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.credit.charge` | 138341830000000000000 | 151453830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_450000_SETTLE_430000.credit.need` | 94547530000000000000 | 111025530000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.balance.charge` | 179485350000000000000 | 188879350000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.balance.need` | 141649090000000000000 | 154409090000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.credit.charge` | 144391830000000000000 | 157503830000000000000 |
| test_B5_amsterdam.log | `B5.MIN_500000_SETTLE_480000.credit.need` | 95097530000000000000 | 111575530000000000000 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.actualGasUsed(PVG=0)` | 1289728 | 1403728 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.handleOps_frame_gas` | 1241015 | 1388619 |
| test_B7_amsterdam.log | `B7.balance_user_writes_0.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 48713 | 15109 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.actualGasUsed(PVG=0)` | 1390891 | 1507501 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.handleOps_frame_gas` | 1353894 | 1505842 |
| test_B7_amsterdam.log | `B7.balance_user_writes_1.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 36997 | 1659 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.actualGasUsed(PVG=0)` | 1490063 | 1606673 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.handleOps_frame_gas` | 1464134 | 1616082 |
| test_B7_amsterdam.log | `B7.balance_user_writes_2.actualGasUsed_minus_frameGas(+ = op billed more than the frame consumed)` | 25929 | -9409 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_first_op.charge_minus_need_aPNTs` | -141093040000000000000 | -150487040000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_first_op.actualGasUsed` | 1282664 | 1368064 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_writes_2.charge_minus_need_aPNTs` | -131222410000000000000 | -142663510000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_writes_2.actualGasUsed` | 1192931 | 1296941 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_first_op.charge_minus_need_aPNTs` | -105999520000000000000 | -119111520000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_first_op.actualGasUsed` | 963632 | 1082832 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_call_reverts.charge_minus_need_aPNTs` | -123047100000000000000 | -134206050000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_user_call_reverts.actualGasUsed` | 1118610 | 1220055 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | -120327570000000000000 | -131768670000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 1093887 | 1197897 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | -97765250000000000000 | -111164350000000000000 |
| test_B8_amsterdam.log | `B8.defaults_200k_160k_5k_175k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 888775 | 1010585 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.settled` | 1 | 0 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.chargeCoversNeed` | 1 | 0 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.charge_minus_need_aPNTs` | 19796260000000000000 | -141372990000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_first_op.actualGasUsed` | 1276219 | 1285209 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.settled` | 1 | 0 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.chargeCoversNeed` | 1 | 0 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.charge_minus_need_aPNTs` | 43808050000000000000 | -133549460000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_writes_2.actualGasUsed` | 1166578 | 1214086 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_first_op.charge_minus_need_aPNTs` | 31254300000000000000 | 8500140000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_first_op.actualGasUsed` | 853023 | 1179079 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_call_reverts.charge_minus_need_aPNTs` | 32206460000000000000 | 26663010000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_user_call_reverts.actualGasUsed` | 1003569 | 1155409 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 42595960000000000000 | 37083860000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 979406 | 1133816 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 32487840000000000000 | 29153740000000000000 |
| test_B8_amsterdam.log | `B8.raw_385k_365k_5k_336k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 866186 | 1018596 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_first_op.charge_minus_need_aPNTs` | 20236260000000000000 | 16870260000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_first_op.actualGasUsed` | 1281719 | 1397719 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_writes_2.charge_minus_need_aPNTs` | 44248050000000000000 | 38735950000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_writes_2.actualGasUsed` | 1172078 | 1326488 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_first_op.charge_minus_need_aPNTs` | 31694300000000000000 | 28328300000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_first_op.actualGasUsed` | 858523 | 1008323 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_call_reverts.charge_minus_need_aPNTs` | 32646460000000000000 | 27103010000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_user_call_reverts.actualGasUsed` | 1009069 | 1160909 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 43035960000000000000 | 37523860000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 984906 | 1139316 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 32927840000000000000 | 29593740000000000000 |
| test_B8_amsterdam.log | `B8.margin_440k_420k_5k_340k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 871686 | 1024096 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_first_op.charge_minus_need_aPNTs` | 15836260000000000000 | 12470260000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_first_op.actualGasUsed` | 1281719 | 1397719 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_writes_2.charge_minus_need_aPNTs` | 39848050000000000000 | 34335950000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_writes_2.actualGasUsed` | 1172078 | 1326488 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_first_op.charge_minus_need_aPNTs` | 27294300000000000000 | 23928300000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_first_op.actualGasUsed` | 858523 | 1008323 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_call_reverts.charge_minus_need_aPNTs` | 28246460000000000000 | 22703010000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_user_call_reverts.actualGasUsed` | 1009069 | 1160909 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_realistic_limits(call 120k,pmVer 900k).charge_minus_need_aPNTs` | 38635960000000000000 | 33123860000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.balance_realistic_limits(call 120k,pmVer 900k).actualGasUsed` | 984906 | 1139316 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_realistic_limits(call 120k,pmVer 700k).charge_minus_need_aPNTs` | 28527840000000000000 | 25193740000000000000 |
| test_B8_amsterdam.log | `B8.Cpostop_low_440k_420k_5k_300k.credit_realistic_limits(call 120k,pmVer 700k).actualGasUsed` | 871686 | 1024096 |
| test_C_wrap_amsterdam.log | `C.wrap.succeeded_200k` | 1870 | 1868 |
| test_C_wrap_amsterdam.log | `C.wrap.succeeded_1M` | 1856 | 1864 |
| test_C_wrap_amsterdam.log | `C.wrap.reverted_200k` | 1870 | 1868 |
| test_C_wrap_amsterdam.log | `C.wrap.bundle_pos_0` | 1870 | 1868 |
