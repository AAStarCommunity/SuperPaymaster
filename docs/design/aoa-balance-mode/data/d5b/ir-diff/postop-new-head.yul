            function fun_postOp_inner(var_context_offset, var_context_length, var_actualGasCost, var_actualUserOpFeePerGas)
            {
                /// @src 8:18366:18398  "if (context.length == 0) return;"
                if /** @src 8:18370:18389  "context.length == 0" */ iszero(var_context_length)
                /// @src 8:18366:18398  "if (context.length == 0) return;"
                {
                    /// @src 8:18391:18398  "return;"
                    leave
                }
                /// @src 8:18977:18989  "uint256 snap"
                let var_snap := /** @src 8:18388:18389  "0" */ 0x00
                /// @src 8:18977:18989  "uint256 snap"
                var_snap := /** @src 8:18388:18389  "0" */ 0x00
                /// @src 8:18999:19129  "if (context.length == CTX_LEN) {..."
                if /** @src 8:19003:19028  "context.length == CTX_LEN" */ eq(var_context_length, /** @src 8:3833:3836  "384" */ 0x0180)
                /// @src 8:18999:19129  "if (context.length == CTX_LEN) {..."
                {
                    /// @src 8:19044:19119  "assembly (\"memory-safe\") { snap := calldataload(add(context.offset, 352)) }"
                    var_snap := calldataload(add(var_context_offset, 352))
                }
                /// @src 8:19138:19177  "uint256 snapSettle = uint32(snap >> 32)"
                let var_snapSettle := convert_uint256_to_uint32(/** @src 8:19159:19177  "uint32(snap >> 32)" */ convert_uint256_to_uint32(/** @src 8:19166:19176  "snap >> 32" */ shift_right_t_uint256_t_uint8(var_snap)))
                /// @src 8:19191:19200  "gasleft()"
                let expr := gas()
                /// @src 8:19204:19258  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle"
                let expr_1 := /** @src 8:18388:18389  "0" */ 0x00
                /// @src 8:19204:19258  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle"
                switch /** @src 8:19204:19219  "snapSettle == 0" */ iszero(var_snapSettle)
                case /** @src 8:19204:19258  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle" */ 0 { expr_1 := var_snapSettle }
                default {
                    expr_1 := /** @src 8:4078:4085  "160_000" */ 0x027100
                }
                /// @src 8:19187:19285  "if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow()"
                if /** @src 8:19191:19259  "gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)" */ lt(expr, expr_1)
                /// @src 8:19187:19285  "if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow()"
                {
                    /// @src 8:19268:19285  "PostOpGasTooLow()"
                    mstore(/** @src 8:18388:18389  "0" */ 0x00, /** @src 8:19268:19285  "PostOpGasTooLow()" */ shl(224, 0x8890295d))
                    revert(/** @src 8:18388:18389  "0" */ 0x00, /** @src 8:19268:19285  "PostOpGasTooLow()" */ 4)
                }
                /// @src 8:19313:19341  "abi.decode(context, (OpCtx))"
                let expr_2030_mpos := abi_decode_struct_OpCtx(var_context_offset, add(var_context_offset, var_context_length))
                /// @src 8:19456:19466  "c.operator"
                let _1 := add(expr_2030_mpos, 128)
                /// @src 8:19442:19583  "if (operators[c.operator].minTxInterval > 0) {..."
                if /** @src 8:19446:19485  "operators[c.operator].minTxInterval > 0" */ iszero(iszero(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ and(extract_from_storage_value_offset_uint48(sload(/** @src 8:19446:19481  "operators[c.operator].minTxInterval" */ add(/** @src 8:19446:19467  "operators[c.operator]" */ mapping_index_access_t_mapping_t_address_t_struct_OperatorConfig_storage_of_t_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:19456:19466  "c.operator" */ _1))), /** @src 8:19446:19481  "operators[c.operator].minTxInterval" */ 1))), /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ 0xffffffffffff)))
                /// @src 8:19442:19583  "if (operators[c.operator].minTxInterval > 0) {..."
                {
                    /// @src 8:19501:19524  "userOpState[c.operator]"
                    let _2 := mapping_index_access_t_mapping_t_address__t_struct_OperatorConfig_storage__of_t_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:19513:19523  "c.operator" */ _1)))
                    /// @src 8:19501:19572  "userOpState[c.operator][c.user].lastTimestamp = uint48(block.timestamp)"
                    update_storage_value_offset_uint48_to_uint48(/** @src 8:19501:19532  "userOpState[c.operator][c.user]" */ mapping_index_access_mapping_address_struct_OperatorConfig_storage_of_address(_2, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:19525:19531  "c.user" */ add(expr_2030_mpos, /** @src 8:19174:19176  "32" */ 0x20)))), /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ and(/** @src 8:19556:19571  "block.timestamp" */ timestamp(), /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ 0xffffffffffff))
                }
                /// @src 8:19676:19684  "c.opHash"
                let _3 := add(expr_2030_mpos, 96)
                /// @src 8:19656:19694  "if (_settledDebtOps[c.opHash]) return;"
                if /** @src 8:19660:19685  "_settledDebtOps[c.opHash]" */ read_from_storage_split_offset_bool(mapping_index_access_mapping_bytes32_struct_Inflight_storage_of_bytes32(/** @src 8:4078:4085  "160_000" */ mload(/** @src 8:19676:19684  "c.opHash" */ _3)))
                /// @src 8:19656:19694  "if (_settledDebtOps[c.opHash]) return;"
                {
                    /// @src 8:19687:19694  "return;"
                    leave
                }
                /// @src 8:19703:19735  "_settledDebtOps[c.opHash] = true"
                update_storage_value_offset_bool_to_bool_15217(/** @src 8:19703:19728  "_settledDebtOps[c.opHash]" */ mapping_index_access_mapping_bytes32_struct_Inflight_storage_of_bytes32(/** @src 8:4078:4085  "160_000" */ mload(/** @src 8:19719:19727  "c.opHash" */ _3)))
                /// @src 8:19745:19783  "operators[c.operator].totalTxSponsored"
                let _4 := add(/** @src 8:19745:19766  "operators[c.operator]" */ mapping_index_access_t_mapping_t_address_t_struct_OperatorConfig_storage_of_t_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:19755:19765  "c.operator" */ _1))), /** @src 8:19745:19783  "operators[c.operator].totalTxSponsored" */ 4)
                /// @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..."
                sstore(_4, /** @src 8:19745:19785  "operators[c.operator].totalTxSponsored++" */ increment_uint256(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ sload(/** @src 8:19745:19785  "operators[c.operator].totalTxSponsored++" */ _4)))
                /// @src 8:20100:20227  "snap == 0..."
                let expr_2 := /** @src 8:18388:18389  "0" */ 0x00
                /// @src 8:20100:20227  "snap == 0..."
                switch /** @src 8:20100:20109  "snap == 0" */ iszero(var_snap)
                case /** @src 8:20100:20227  "snap == 0..." */ 0 {
                    /// @src 8:20179:20206  "uint256(uint32(snap >> 96))"
                    let expr_3 := convert_uint256_to_uint32(/** @src 8:20187:20205  "uint32(snap >> 96)" */ convert_uint256_to_uint32(/** @src 8:20194:20204  "snap >> 96" */ convert_bytes20_to_address(var_snap)))
                    /// @src 8:20100:20227  "snap == 0..."
                    expr_2 := /** @src 8:20179:20227  "uint256(uint32(snap >> 96)) + uint32(snap >> 64)" */ checked_add_uint256(expr_3, convert_uint256_to_uint32(/** @src 8:20209:20227  "uint32(snap >> 64)" */ convert_uint256_to_uint32(/** @src 8:20216:20226  "snap >> 64" */ shift_right_uint256_uint8(var_snap))))
                }
                default /// @src 8:20100:20227  "snap == 0..."
                {
                    expr_2 := /** @src 8:20124:20164  "uint256(c.postOpGas) + LEGACY_C_WRAP_GAS" */ checked_add_uint256_15221(/** @src 8:20124:20144  "uint256(c.postOpGas)" */ cleanup_from_storage_uint128(/** @src 8:4078:4085  "160_000" */ cleanup_from_storage_uint128(mload(/** @src 8:20132:20143  "c.postOpGas" */ add(expr_2030_mpos, 224)))))
                }
                /// @src 8:20278:20296  "uint256(c.callGas)"
                let expr_4 := cleanup_from_storage_uint128(/** @src 8:4078:4085  "160_000" */ cleanup_from_storage_uint128(mload(/** @src 8:20286:20295  "c.callGas" */ add(expr_2030_mpos, 192))))
                /// @src 8:20398:20420  "actualGasCost + bufWei"
                let expr_5 := checked_add_uint256(var_actualGasCost, /** @src 8:20254:20347  "(bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas" */ checked_mul_uint256(/** @src 8:20255:20322  "bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)" */ checked_add_uint256(expr_2, /** @src 8:20264:20322  "Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)" */ fun_ceilDiv(/** @src 8:20277:20316  "(uint256(c.callGas) + c.postOpGas) * 10" */ checked_mul_uint256_15222(/** @src 8:20278:20310  "uint256(c.callGas) + c.postOpGas" */ checked_add_uint256(expr_4, cleanup_from_storage_uint128(/** @src 8:4078:4085  "160_000" */ cleanup_from_storage_uint128(mload(/** @src 8:20299:20310  "c.postOpGas" */ add(expr_2030_mpos, 224)))))))), /** @src 8:20254:20347  "(bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas" */ var_actualUserOpFeePerGas))
                /// @src 8:20397:20440  "(actualGasCost + bufWei) * uint256(c.price)"
                let expr_6 := checked_mul_uint256(expr_5, /** @src 10:8928:8929  "0" */ mload(/** @src 8:20432:20439  "c.price" */ add(expr_2030_mpos, 256)))
                /// @src 8:20449:20474  "10 ** uint256(c.decimals)"
                let expr_7 := checked_exp_rational_by_uint256(/** @src 8:20455:20474  "uint256(c.decimals)" */ cleanup_from_storage_uint8(/** @src 10:8928:8929  "0" */ cleanup_from_storage_uint8(mload(/** @src 8:20463:20473  "c.decimals" */ add(expr_2030_mpos, 288)))))
                /// @src 8:20372:20519  "Math.mulDiv(..."
                let expr_8 := fun_mulDiv_15224(expr_6, /** @src 8:20448:20489  "(10 ** uint256(c.decimals)) * c.aPriceUSD" */ checked_mul_uint256(expr_7, /** @src 8:4137:4143  "30_000" */ mload(/** @src 8:20478:20489  "c.aPriceUSD" */ add(expr_2030_mpos, 320))))
                /// @src 8:20529:20634  "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil)"
                let var_charge := /** @src 8:20546:20634  "Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil)" */ fun_mulDiv_15195(expr_8, /** @src 8:20564:20596  "BPS_DENOMINATOR + protocolFeeBPS" */ checked_add_uint256_15193(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ sload(/** @src 8:20582:20596  "protocolFeeBPS" */ 0x0d)))
                /// @src 8:20657:20661  "c.a0"
                let _5 := add(expr_2030_mpos, 64)
                /// @src 8:4137:4143  "30_000"
                let _6 := mload(/** @src 8:20657:20661  "c.a0" */ _5)
                /// @src 8:20644:20676  "if (charge > c.a0) charge = c.a0"
                if /** @src 8:20648:20661  "charge > c.a0" */ gt(var_charge, _6)
                /// @src 8:20644:20676  "if (charge > c.a0) charge = c.a0"
                {
                    /// @src 8:20663:20676  "charge = c.a0"
                    var_charge := _6
                }
                /// @src 8:20885:21091  "if (c.mode == MODE_BALANCE) {..."
                switch /** @src 8:20889:20911  "c.mode == MODE_BALANCE" */ eq(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ and(/** @src 10:8928:8929  "0" */ cleanup_from_storage_uint8(mload(/** @src 8:20889:20895  "c.mode" */ add(expr_2030_mpos, 160))), /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ 0xff), /** @src 8:19446:19481  "operators[c.operator].minTxInterval" */ 1)
                case /** @src 8:20885:21091  "if (c.mode == MODE_BALANCE) {..." */ 0 {
                    /// @src 8:21019:21054  "IxPNTsTokenV2(c.token).settleCredit"
                    let expr_address := convert_contract_IRegistry_to_address(/** @src 8:21019:21041  "IxPNTsTokenV2(c.token)" */ convert_contract_IRegistry_to_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:21033:21040  "c.token" */ expr_2030_mpos))))
                    /// @src 8:21055:21061  "c.user"
                    let _7 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:21055:21061  "c.user" */ add(expr_2030_mpos, /** @src 8:19174:19176  "32" */ 0x20)))
                    /// @src 8:4078:4085  "160_000"
                    let _8 := mload(/** @src 8:21063:21071  "c.opHash" */ _3)
                    /// @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    let _9 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ mload(/** @src 8:20657:20661  "c.a0" */ 64)
                    /// @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    mstore(_9, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ shl(227, 0x0375e881))
                    /// @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    let _10 := call(gas(), expr_address, /** @src 8:18388:18389  "0" */ 0x00, /** @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ _9, sub(abi_encode_address_bytes32_uint256(add(_9, /** @src 8:19745:19783  "operators[c.operator].totalTxSponsored" */ 4), /** @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ _7, _8, var_charge), _9), _9, /** @src 8:19174:19176  "32" */ 0x20)
                    /// @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    if iszero(_10) { revert_forward() }
                    if _10
                    {
                        let _11 := /** @src 8:19174:19176  "32" */ 0x20
                        /// @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                        if gt(/** @src 8:19174:19176  "32" */ 0x20, /** @src 8:21019:21080  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ returndatasize()) { _11 := returndatasize() }
                        finalize_allocation(_9, _11)
                        pop(abi_decode_uint256_fromMemory(_9, add(_9, _11)))
                    }
                }
                default /// @src 8:20885:21091  "if (c.mode == MODE_BALANCE) {..."
                {
                    /// @src 8:20927:20962  "IxPNTsTokenV2(c.token).settleLocked"
                    let expr_2192_address := convert_contract_IRegistry_to_address(/** @src 8:20927:20949  "IxPNTsTokenV2(c.token)" */ convert_contract_IRegistry_to_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:20941:20948  "c.token" */ expr_2030_mpos))))
                    /// @src 8:20963:20969  "c.user"
                    let _12 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:20963:20969  "c.user" */ add(expr_2030_mpos, /** @src 8:19174:19176  "32" */ 0x20)))
                    /// @src 8:4078:4085  "160_000"
                    let _13 := mload(/** @src 8:20971:20979  "c.opHash" */ _3)
                    /// @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    let _14 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ mload(/** @src 8:20657:20661  "c.a0" */ 64)
                    /// @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    mstore(_14, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ shl(225, 0x3f245de7))
                    /// @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    let _15 := call(gas(), expr_2192_address, /** @src 8:18388:18389  "0" */ 0x00, /** @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ _14, sub(abi_encode_address_bytes32_uint256(add(_14, /** @src 8:19745:19783  "operators[c.operator].totalTxSponsored" */ 4), /** @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ _12, _13, var_charge), _14), _14, /** @src 8:19174:19176  "32" */ 0x20)
                    /// @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    if iszero(_15) { revert_forward() }
                    if _15
                    {
                        let _16 := /** @src 8:19174:19176  "32" */ 0x20
                        /// @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                        if gt(/** @src 8:19174:19176  "32" */ 0x20, /** @src 8:20927:20988  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ returndatasize()) { _16 := returndatasize() }
                        finalize_allocation(_14, _16)
                        pop(abi_decode_uint256_fromMemory(_14, add(_14, _16)))
                    }
                }
                /// @src 8:21206:21232  "delete _inflight[c.opHash]"
                let slot := /** @src 8:21213:21232  "_inflight[c.opHash]" */ mapping_index_access_mapping_bytes32__struct_Inflight_storage__of_bytes32(/** @src 8:4078:4085  "160_000" */ mload(/** @src 8:21223:21231  "c.opHash" */ _3))
                /// @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..."
                let offset := /** @src 8:21947:21957  "f.operator" */ 0
                /// @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..."
                offset := /** @src 8:21947:21957  "f.operator" */ 0
                /// @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..."
                sstore(slot, /** @src -1:-1:-1 */ 0)
                /// @src 8:21269:21274  "false"
                fun__setInflightLive(/** @src 8:4078:4085  "160_000" */ mload(/** @src 8:21259:21267  "c.opHash" */ _3))
                /// @src 8:21323:21345  "uint128(c.a0 - charge)"
                let expr_9 := cleanup_from_storage_uint128(/** @src 8:21331:21344  "c.a0 - charge" */ checked_sub_uint256(/** @src 8:4137:4143  "30_000" */ mload(/** @src 8:21331:21335  "c.a0" */ _5), /** @src 8:21331:21344  "c.a0 - charge" */ var_charge))
                /// @src 8:21285:21306  "operators[c.operator]"
                let _17 := mapping_index_access_t_mapping_t_address_t_struct_OperatorConfig_storage_of_t_address(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:21295:21305  "c.operator" */ _1)))
                /// @src 8:21285:21345  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)"
                update_storage_value_offset_uint128_to_uint128(_17, checked_add_uint128(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ cleanup_from_storage_uint128(sload(/** @src 8:21285:21345  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ _17)), expr_9))
                /// @src 8:21355:21380  "protocolRevenue += charge"
                update_storage_value_offset_t_uint256_to_t_uint256(checked_add_uint256(/** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ sload(/** @src 8:21355:21380  "protocolRevenue += charge" */ 0x10), var_charge))
                /// @src 8:21433:21443  "c.operator"
                let _18 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:21433:21443  "c.operator" */ _1))
                /// @src 8:21445:21451  "c.user"
                let _19 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ convert_contract_IRegistry_to_address(mload(/** @src 8:21445:21451  "c.user" */ add(expr_2030_mpos, /** @src 8:19174:19176  "32" */ 0x20)))
                /// @src 8:21396:21466  "ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge)"
                let _20 := /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ mload(/** @src 8:20657:20661  "c.a0" */ 64)
                /// @src 8:21396:21466  "ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge)"
                log3(_20, sub(abi_encode_uint256_uint256(_20, expr_8, var_charge), _20), 0xcde7e91a718e2439d8ff2a679ad52713e82a37b72622fb530c8c41039fdd5bf0, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ and(/** @src 8:21396:21466  "ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge)" */ _18, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ 0xffffffffffffffffffffffffffffffffffffffff), and(/** @src 8:21396:21466  "ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge)" */ _19, /** @src 8:1983:24394  "contract SuperPaymaster is SuperPaymasterStorage, IVersioned {..." */ 0xffffffffffffffffffffffffffffffffffffffff))
            }
