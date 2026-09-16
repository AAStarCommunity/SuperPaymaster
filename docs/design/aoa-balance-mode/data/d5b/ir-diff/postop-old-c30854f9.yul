            function fun_postOp_inner(var_context_offset, var_context_length, var_actualGasCost, var_actualUserOpFeePerGas)
            {
                /// @src 8:71715:71734  "context.length == 0"
                let _1 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:71711:71743  "if (context.length == 0) return;"
                if /** @src 8:71715:71734  "context.length == 0" */ iszero(var_context_length)
                /// @src 8:71711:71743  "if (context.length == 0) return;"
                {
                    /// @src 8:71736:71743  "return;"
                    leave
                }
                /// @src 8:72327:72339  "uint256 snap"
                let var_snap := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:72327:72339  "uint256 snap"
                var_snap := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:72349:72479  "if (context.length == CTX_LEN) {..."
                if /** @src 8:72353:72378  "context.length == CTX_LEN" */ eq(var_context_length, /** @src 8:4192:4195  "384" */ 0x0180)
                /// @src 8:72349:72479  "if (context.length == CTX_LEN) {..."
                {
                    /// @src 8:72394:72469  "assembly (\"memory-safe\") { snap := calldataload(add(context.offset, 352)) }"
                    var_snap := calldataload(add(var_context_offset, 352))
                }
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let cleaned := and(shr(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:4192:4195  "384" */ var_snap), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffff)
                /// @src 8:72541:72550  "gasleft()"
                let expr := gas()
                /// @src 8:72554:72608  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle"
                let expr_1 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:72554:72608  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle"
                switch /** @src 8:72554:72569  "snapSettle == 0" */ iszero(cleaned)
                case /** @src 8:72554:72608  "snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle" */ 0 { expr_1 := cleaned }
                default {
                    expr_1 := /** @src 8:10704:10711  "160_000" */ 0x027100
                }
                /// @src 8:72537:72635  "if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow()"
                if /** @src 8:72541:72609  "gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)" */ lt(expr, expr_1)
                /// @src 8:72537:72635  "if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow()"
                {
                    /// @src 8:72618:72635  "PostOpGasTooLow()"
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:72618:72635  "PostOpGasTooLow()" */ shl(224, 0x8890295d))
                    revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:72618:72635  "PostOpGasTooLow()" */ 4)
                }
                /// @src 8:10704:10711  "160_000"
                let _2 := slt(sub(/** @src 8:72663:72691  "abi.decode(context, (OpCtx))" */ add(var_context_offset, var_context_length), /** @src 8:10704:10711  "160_000" */ var_context_offset), 352)
                if _2
                {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    revert(/** @src 8:71733:71734  "0" */ 0x00, 0x00)
                }
                /// @src 8:10704:10711  "160_000"
                _2 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let memPtr := mload(64)
                let newFreePtr := add(memPtr, /** @src 8:10704:10711  "160_000" */ 352)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                if or(gt(newFreePtr, 0xffffffffffffffff), lt(newFreePtr, memPtr))
                {
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    mstore(4, 0x41)
                    revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0x24)
                }
                mstore(64, newFreePtr)
                /// @src 8:10704:10711  "160_000"
                mstore(memPtr, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ abi_decode_address(/** @src 8:10704:10711  "160_000" */ var_context_offset))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let _3 := abi_decode_address(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, /** @src 8:72524:72526  "32" */ 0x20))
                /// @src 8:10704:10711  "160_000"
                let _4 := add(memPtr, /** @src 8:72524:72526  "32" */ 0x20)
                /// @src 8:10704:10711  "160_000"
                mstore(_4, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ _3)
                /// @src 8:10704:10711  "160_000"
                let _5 := add(memPtr, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)
                /// @src 8:10704:10711  "160_000"
                mstore(_5, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ calldataload(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)))
                /// @src 8:10704:10711  "160_000"
                let _6 := add(memPtr, 96)
                mstore(_6, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ calldataload(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 96)))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let _7 := abi_decode_address(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 128))
                let _8 := add(memPtr, 128)
                mstore(_8, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ _7)
                let _9 := abi_decode_uint8(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 160))
                let _10 := add(memPtr, 160)
                mstore(_10, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ _9)
                /// @src 8:10704:10711  "160_000"
                let _11 := abi_decode_uint128(add(var_context_offset, 192))
                let _12 := add(memPtr, 192)
                mstore(_12, _11)
                let _13 := abi_decode_uint128(add(var_context_offset, 224))
                let _14 := add(memPtr, 224)
                mstore(_14, _13)
                let _15 := add(memPtr, 256)
                mstore(_15, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ calldataload(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 256)))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let _16 := abi_decode_uint8(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 288))
                let _17 := add(memPtr, 288)
                mstore(_17, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ _16)
                /// @src 8:10704:10711  "160_000"
                let _18 := add(memPtr, 320)
                mstore(_18, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ calldataload(/** @src 8:10704:10711  "160_000" */ add(var_context_offset, 320)))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(_7, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:72796:72805  "operators" */ 0x05)
                /// @src 8:72792:72933  "if (operators[c.operator].minTxInterval > 0) {..."
                if /** @src 8:72796:72835  "operators[c.operator].minTxInterval > 0" */ iszero(iszero(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(shr(/** @src 8:10704:10711  "160_000" */ 192, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ sload(/** @src 8:72796:72831  "operators[c.operator].minTxInterval" */ add(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64), 1))), 0xffffffffffff)))
                /// @src 8:72792:72933  "if (operators[c.operator].minTxInterval > 0) {..."
                {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(mload(/** @src 8:72863:72873  "c.operator" */ _8), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff))
                    mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:72851:72862  "userOpState" */ 0x06)
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let dataSlot := keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)
                    /// @src 8:72851:72882  "userOpState[c.operator][c.user]"
                    let key := /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(mload(/** @src 8:72875:72881  "c.user" */ _4), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                    /// @src 8:72851:72882  "userOpState[c.operator][c.user]"
                    let dataSlot_1 := /** @src 8:71733:71734  "0" */ 0x00
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(key, 0xffffffffffffffffffffffffffffffffffffffff))
                    mstore(0x20, /** @src 8:72851:72882  "userOpState[c.operator][c.user]" */ dataSlot)
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    dataSlot_1 := keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0x40)
                    /// @src 8:24945:24952  "1 hours"
                    sstore(/** @src 8:72851:72882  "userOpState[c.operator][c.user]" */ dataSlot_1, /** @src 8:24945:24952  "1 hours" */ or(and(sload(/** @src 8:72851:72882  "userOpState[c.operator][c.user]" */ dataSlot_1), /** @src 8:24945:24952  "1 hours" */ not(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffff)), and(and(/** @src 8:72906:72921  "block.timestamp" */ timestamp(), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffff), 0xffffffffffff)))
                }
                mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:10704:10711  "160_000" */ mload(/** @src 8:73026:73034  "c.opHash" */ _6))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:73010:73025  "_settledDebtOps" */ 0x21)
                /// @src 8:73006:73044  "if (_settledDebtOps[c.opHash]) return;"
                if /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(sload(keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)), 0xff)
                /// @src 8:73006:73044  "if (_settledDebtOps[c.opHash]) return;"
                {
                    /// @src 8:73037:73044  "return;"
                    leave
                }
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:10704:10711  "160_000" */ mload(/** @src 8:73069:73077  "c.opHash" */ _6))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:73010:73025  "_settledDebtOps" */ 0x21)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let dataSlot_2 := keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)
                /// @src 8:24945:24952  "1 hours"
                sstore(dataSlot_2, or(and(sload(dataSlot_2), not(255)), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 1))
                mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(mload(/** @src 8:73105:73115  "c.operator" */ _8), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:72796:72805  "operators" */ 0x05)
                /// @src 8:73095:73133  "operators[c.operator].totalTxSponsored"
                let _19 := add(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ keccak256(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64), /** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let _20 := sload(/** @src 8:73095:73135  "operators[c.operator].totalTxSponsored++" */ _19)
                /// @src 8:10704:10711  "160_000"
                if eq(_20, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ not(0))
                /// @src 8:10704:10711  "160_000"
                {
                    /// @src 8:24945:24952  "1 hours"
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                    mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                    revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ 0x24)
                }
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                sstore(_19, /** @src 8:10704:10711  "160_000" */ add(_20, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 1))
                /// @src 8:73450:73577  "snap == 0..."
                let expr_2 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 8:73450:73577  "snap == 0..."
                switch /** @src 8:73450:73459  "snap == 0" */ iszero(var_snap)
                case /** @src 8:73450:73577  "snap == 0..." */ 0 {
                    expr_2 := /** @src 8:73529:73577  "uint256(uint32(snap >> 96)) + uint32(snap >> 64)" */ checked_add_uint256(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(shr(/** @src 8:10704:10711  "160_000" */ 96, /** @src 8:4192:4195  "384" */ var_snap), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffff), and(shr(64, /** @src 8:4192:4195  "384" */ var_snap), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffff))
                }
                default /// @src 8:73450:73577  "snap == 0..."
                {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let cleaned_1 := and(/** @src 8:10704:10711  "160_000" */ mload(/** @src 8:73482:73493  "c.postOpGas" */ _14), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff)
                    let sum := add(cleaned_1, /** @src 8:10763:10769  "30_000" */ 0x7530)
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    if gt(cleaned_1, sum)
                    {
                        /// @src 8:24945:24952  "1 hours"
                        mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                        mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                        revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ 0x24)
                    }
                    /// @src 8:73450:73577  "snap == 0..."
                    expr_2 := sum
                }
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let cleaned_2 := and(/** @src 8:10704:10711  "160_000" */ mload(/** @src 8:73636:73645  "c.callGas" */ _12), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff)
                /// @src 8:73628:73660  "uint256(c.callGas) + c.postOpGas"
                let expr_3 := checked_add_uint256(cleaned_2, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(/** @src 8:10704:10711  "160_000" */ mload(/** @src 8:73649:73660  "c.postOpGas" */ _14), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff))
                /// @src 8:10763:10769  "30_000"
                let product := mul(expr_3, /** @src 8:73664:73666  "10" */ 0x0a)
                /// @src 8:10763:10769  "30_000"
                if iszero(or(iszero(expr_3), eq(/** @src 8:73664:73666  "10" */ 0x0a, /** @src 8:10763:10769  "30_000" */ div(product, expr_3))))
                {
                    /// @src 8:24945:24952  "1 hours"
                    mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                    mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                    revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ 0x24)
                }
                /// @src 8:73614:73672  "Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)"
                let var := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 30:3210:3217  "uint256"
                let var_1 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 30:3210:3217  "uint256"
                var := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 30:3229:3356  "if (b == 0) {..."
                var_1 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 30:3444:3472  "a == 0 ? 0 : (a - 1) / b + 1"
                let expr_4 := /** @src 8:71733:71734  "0" */ 0x00
                /// @src 30:3444:3472  "a == 0 ? 0 : (a - 1) / b + 1"
                switch /** @src 30:3444:3450  "a == 0" */ iszero(product)
                case /** @src 30:3444:3472  "a == 0 ? 0 : (a - 1) / b + 1" */ 0 {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let diff := add(product, not(0))
                    if gt(diff, product)
                    {
                        /// @src 8:24945:24952  "1 hours"
                        mstore(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                        mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                        revert(/** @src 8:71733:71734  "0" */ 0x00, /** @src 8:24945:24952  "1 hours" */ 0x24)
                    }
                    /// @src 30:3457:3468  "(a - 1) / b"
                    let r := /** @src 8:71733:71734  "0" */ 0x00
                    /// @src 8:29921:29925  "1000"
                    _1 := /** @src 8:71733:71734  "0" */ 0x00
                    /// @src 8:29921:29925  "1000"
                    r := div(diff, /** @src 8:73668:73671  "100" */ 0x64)
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let sum_1 := add(r, 1)
                    if gt(r, sum_1)
                    {
                        /// @src 8:24945:24952  "1 hours"
                        mstore(/** @src -1:-1:-1 */ 0, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                        mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                        revert(/** @src -1:-1:-1 */ 0, /** @src 8:24945:24952  "1 hours" */ 0x24)
                    }
                    /// @src 30:3444:3472  "a == 0 ? 0 : (a - 1) / b + 1"
                    expr_4 := sum_1
                }
                default {
                    expr_4 := /** @src -1:-1:-1 */ _1
                }
                /// @src 30:3437:3472  "return a == 0 ? 0 : (a - 1) / b + 1"
                var := expr_4
                /// @src 8:73748:73770  "actualGasCost + bufWei"
                let expr_5 := checked_add_uint256(var_actualGasCost, /** @src 8:73604:73697  "(bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas" */ checked_mul_uint256(/** @src 8:73605:73672  "bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)" */ checked_add_uint256(expr_2, /** @src 8:73614:73672  "Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)" */ expr_4), /** @src 8:73604:73697  "(bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas" */ var_actualUserOpFeePerGas))
                /// @src 8:73747:73790  "(actualGasCost + bufWei) * uint256(c.price)"
                let expr_6 := checked_mul_uint256(expr_5, /** @src 8:7012:7013  "0" */ mload(/** @src 8:73782:73789  "c.price" */ _15))
                /// @src 8:73799:73824  "10 ** uint256(c.decimals)"
                let expr_7 := checked_exp_rational_by_uint256(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(/** @src 8:7012:7013  "0" */ mload(/** @src 8:73813:73823  "c.decimals" */ _17), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xff))
                /// @src 8:73722:73869  "Math.mulDiv(..."
                let expr_8 := fun_mulDiv(expr_6, /** @src 8:73798:73839  "(10 ** uint256(c.decimals)) * c.aPriceUSD" */ checked_mul_uint256(expr_7, /** @src 8:5128:5141  "100_000 * 1e8" */ mload(/** @src 8:73828:73839  "c.aPriceUSD" */ _18)))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let sum_2 := add(/** @src 8:10986:10991  "10000" */ 0x2710, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ sload(/** @src 8:73932:73946  "protocolFeeBPS" */ 0x0d))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                if gt(/** @src 8:10986:10991  "10000" */ 0x2710, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ sum_2)
                {
                    /// @src 8:24945:24952  "1 hours"
                    mstore(/** @src 8:71733:71734  "0" */ _1, /** @src 8:24945:24952  "1 hours" */ shl(224, 0x4e487b71))
                    mstore(/** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4, /** @src 8:24945:24952  "1 hours" */ 0x11)
                    revert(/** @src 8:71733:71734  "0" */ _1, /** @src 8:24945:24952  "1 hours" */ 0x24)
                }
                /// @src 8:73879:73984  "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil)"
                let var_charge := /** @src 8:73896:73984  "Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil)" */ fun_mulDiv_52756(expr_8, /** @src 8:73914:73946  "BPS_DENOMINATOR + protocolFeeBPS" */ sum_2)
                /// @src 8:5128:5141  "100_000 * 1e8"
                let _21 := mload(/** @src 8:74007:74011  "c.a0" */ _5)
                /// @src 8:73994:74026  "if (charge > c.a0) charge = c.a0"
                if /** @src 8:73998:74011  "charge > c.a0" */ gt(var_charge, _21)
                /// @src 8:73994:74026  "if (charge > c.a0) charge = c.a0"
                {
                    /// @src 8:74013:74026  "charge = c.a0"
                    var_charge := _21
                }
                /// @src 8:74235:74441  "if (c.mode == MODE_BALANCE) {..."
                switch /** @src 8:74239:74261  "c.mode == MODE_BALANCE" */ eq(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(/** @src 8:7012:7013  "0" */ mload(/** @src 8:74239:74245  "c.mode" */ _10), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xff), 1)
                case /** @src 8:74235:74441  "if (c.mode == MODE_BALANCE) {..." */ 0 {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let cleaned_3 := and(mload(/** @src 8:74383:74390  "c.token" */ memPtr), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                    let cleaned_4 := and(mload(/** @src 8:74405:74411  "c.user" */ _4), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                    /// @src 8:10704:10711  "160_000"
                    let _22 := mload(/** @src 8:74413:74421  "c.opHash" */ _6)
                    /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    let _23 := /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ mload(64)
                    /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    mstore(_23, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ shl(227, 0x0375e881))
                    /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    let _24 := call(gas(), cleaned_3, /** @src 8:71733:71734  "0" */ _1, /** @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ _23, sub(abi_encode_address_bytes32_uint256(add(_23, /** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4), /** @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ cleaned_4, _22, var_charge), _23), _23, /** @src 8:72524:72526  "32" */ 0x20)
                    /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    if iszero(_24)
                    {
                        /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                        let pos := mload(64)
                        returndatacopy(pos, /** @src 8:71733:71734  "0" */ _1, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ returndatasize())
                        revert(pos, returndatasize())
                    }
                    /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                    if _24
                    {
                        let _25 := /** @src 8:72524:72526  "32" */ 0x20
                        /// @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)"
                        if gt(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:74369:74430  "IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge)" */ returndatasize()) { _25 := returndatasize() }
                        finalize_allocation(_23, _25)
                        pop(abi_decode_uint256_fromMemory(_23, add(_23, _25)))
                    }
                }
                default /// @src 8:74235:74441  "if (c.mode == MODE_BALANCE) {..."
                {
                    /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                    let cleaned_5 := and(mload(/** @src 8:74291:74298  "c.token" */ memPtr), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                    let cleaned_6 := and(mload(/** @src 8:74313:74319  "c.user" */ _4), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                    /// @src 8:10704:10711  "160_000"
                    let _26 := mload(/** @src 8:74321:74329  "c.opHash" */ _6)
                    /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    let _27 := /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ mload(64)
                    /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    mstore(_27, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ shl(225, 0x3f245de7))
                    /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    let _28 := call(gas(), cleaned_5, /** @src 8:71733:71734  "0" */ _1, /** @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ _27, sub(abi_encode_address_bytes32_uint256(add(_27, /** @src 8:73095:73133  "operators[c.operator].totalTxSponsored" */ 4), /** @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ cleaned_6, _26, var_charge), _27), _27, /** @src 8:72524:72526  "32" */ 0x20)
                    /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    if iszero(_28)
                    {
                        /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                        let pos_1 := mload(64)
                        returndatacopy(pos_1, /** @src 8:71733:71734  "0" */ _1, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ returndatasize())
                        revert(pos_1, returndatasize())
                    }
                    /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                    if _28
                    {
                        let _29 := /** @src 8:72524:72526  "32" */ 0x20
                        /// @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)"
                        if gt(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:74277:74338  "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge)" */ returndatasize()) { _29 := returndatasize() }
                        finalize_allocation(_27, _29)
                        pop(abi_decode_uint256_fromMemory(_27, add(_27, _29)))
                    }
                }
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:71733:71734  "0" */ _1, /** @src 8:10704:10711  "160_000" */ mload(/** @src 8:74573:74581  "c.opHash" */ _6))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:74563:74572  "_inflight" */ 0x25)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                sstore(keccak256(/** @src 8:71733:71734  "0" */ _1, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64), /** @src 8:71733:71734  "0" */ _1)
                /// @src 8:78904:78932  "assembly { tstore(slot, v) }"
                tstore(/** @src 8:78841:78862  "_inflightSlot(opHash)" */ fun_inflightSlot(/** @src 8:10704:10711  "160_000" */ mload(/** @src 8:74609:74617  "c.opHash" */ _6)), /** @src 8:71733:71734  "0" */ _1)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let cleaned_7 := and(/** @src 8:74681:74694  "c.a0 - charge" */ checked_sub_uint256(/** @src 8:5128:5141  "100_000 * 1e8" */ mload(/** @src 8:74681:74685  "c.a0" */ _5), /** @src 8:74681:74694  "c.a0 - charge" */ var_charge), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff)
                mstore(/** @src 8:71733:71734  "0" */ _1, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(mload(/** @src 8:74645:74655  "c.operator" */ _8), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(/** @src 8:72524:72526  "32" */ 0x20, /** @src 8:72796:72805  "operators" */ 0x05)
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let dataSlot_3 := keccak256(/** @src 8:71733:71734  "0" */ _1, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64)
                sstore(/** @src 8:74635:74695  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ dataSlot_3, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ or(and(sload(/** @src 8:74635:74695  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ dataSlot_3), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ not(0xffffffffffffffffffffffffffffffff)), and(/** @src 8:74635:74695  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ checked_add_uint128(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ and(sload(/** @src 8:74635:74695  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ dataSlot_3), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff), /** @src 8:74635:74695  "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge)" */ cleaned_7), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffff)))
                sstore(/** @src 8:74705:74730  "protocolRevenue += charge" */ 0x10, checked_add_uint256(/** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ sload(/** @src 8:74705:74730  "protocolRevenue += charge" */ 0x10), var_charge))
                /// @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..."
                let cleaned_8 := and(mload(/** @src 8:74767:74777  "c.operator" */ _8), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                let cleaned_9 := and(mload(/** @src 8:74779:74785  "c.user" */ _4), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 0xffffffffffffffffffffffffffffffffffffffff)
                /// @src 8:74746:74800  "TransactionSponsored(c.operator, c.user, aGas, charge)"
                let _30 := /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ mload(64)
                mstore(_30, expr_8)
                mstore(/** @src 8:11042:11046  "2000" */ add(_30, /** @src 8:72524:72526  "32" */ 0x20), /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ var_charge)
                /// @src 8:74746:74800  "TransactionSponsored(c.operator, c.user, aGas, charge)"
                log3(_30, /** @src 8:997:87970  "contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {..." */ 64, /** @src 8:74746:74800  "TransactionSponsored(c.operator, c.user, aGas, charge)" */ 0xcde7e91a718e2439d8ff2a679ad52713e82a37b72622fb530c8c41039fdd5bf0, cleaned_8, cleaned_9)
            }
