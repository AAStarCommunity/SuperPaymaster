// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";

/// @notice Source-derived guard for every SP/SPAdmin selector whose access decision admits
///         `BLS_AGGREGATOR`. The BLS worktree consumes the same expected set in its generic-path
///         denylist check; adding another BLS-authorized SP function must turn this test red.
contract SuperPaymasterBLSSelectorSurfaceTest is Test {
    bytes4 internal constant QUEUE_SLASH = bytes4(keccak256("queueSlash(address)"));
    bytes4 internal constant UPDATE_PRICE_DVT = bytes4(keccak256("updatePriceDVT(int256,uint256,bytes,uint8)"));
    bytes4 internal constant EXECUTE_SLASH_BLS = bytes4(keccak256("executeSlashWithBLS(address,uint8,bytes)"));

    function test_SP_R4_H01_source_derived_bls_authorized_selector_set_is_exact() public {
        bytes memory source = bytes.concat(
            bytes(vm.readFile("contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol")),
            bytes(vm.readFile("contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol"))
        );
        bytes memory marker = bytes("\n    function ");
        uint256 cursor;
        uint256 found;
        bool sawQueue;
        bool sawPrice;
        bool sawSlash;

        while (true) {
            uint256 declaration = _find(source, marker, cursor, source.length);
            if (declaration == type(uint256).max) break;
            uint256 nameStart = declaration + marker.length;
            uint256 open = _findByte(source, bytes1("{"), nameStart, source.length);
            if (open == type(uint256).max) break;
            uint256 close = _matchingBrace(source, open);

            // Access checks use either msg.sender directly or the local `actor = msg.sender`.
            bool mentionsBls = _contains(source, bytes("BLS_AGGREGATOR"), open, close);
            bool checksSender = _contains(source, bytes("msg.sender"), open, close);
            if (mentionsBls && checksSender) {
                bytes32 name = _functionNameHash(source, nameStart, open);
                ++found;
                if (name == keccak256("queueSlash")) {
                    sawQueue = true;
                    assertEq(QUEUE_SLASH, bytes4(keccak256("queueSlash(address)")));
                } else if (name == keccak256("updatePriceDVT")) {
                    sawPrice = true;
                    assertEq(UPDATE_PRICE_DVT, bytes4(keccak256("updatePriceDVT(int256,uint256,bytes,uint8)")));
                } else if (name == keccak256("executeSlashWithBLS")) {
                    sawSlash = true;
                    assertEq(EXECUTE_SLASH_BLS, bytes4(keccak256("executeSlashWithBLS(address,uint8,bytes)")));
                } else {
                    assertTrue(false, "unexpected BLS-authorized SP/SPAdmin function");
                }
            }
            cursor = close + 1;
        }

        assertEq(found, 3, "BLS-authorized selector count changed");
        assertTrue(sawQueue && sawPrice && sawSlash, "expected BLS selector missing");
    }

    function _functionNameHash(bytes memory source, uint256 start, uint256 limit) internal pure returns (bytes32) {
        uint256 end = start;
        while (end < limit && source[end] != bytes1("(") && source[end] != bytes1(" ")) ++end;
        bytes memory name = new bytes(end - start);
        for (uint256 i; i < name.length; ++i) {
            name[i] = source[start + i];
        }
        return keccak256(name);
    }

    function _matchingBrace(bytes memory source, uint256 open) internal pure returns (uint256) {
        uint256 depth = 1;
        for (uint256 i = open + 1; i < source.length; ++i) {
            if (source[i] == bytes1("{")) {
                ++depth;
            } else if (source[i] == bytes1("}")) {
                if (--depth == 0) return i;
            }
        }
        revert("unclosed function body");
    }

    function _contains(bytes memory haystack, bytes memory needle, uint256 start, uint256 end)
        internal
        pure
        returns (bool)
    {
        return _find(haystack, needle, start, end) != type(uint256).max;
    }

    function _find(bytes memory haystack, bytes memory needle, uint256 start, uint256 end)
        internal
        pure
        returns (uint256)
    {
        if (needle.length == 0 || end < needle.length) return type(uint256).max;
        for (uint256 i = start; i + needle.length <= end; ++i) {
            bool equal = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    equal = false;
                    break;
                }
            }
            if (equal) return i;
        }
        return type(uint256).max;
    }

    function _findByte(bytes memory haystack, bytes1 needle, uint256 start, uint256 end)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = start; i < end; ++i) {
            if (haystack[i] == needle) return i;
        }
        return type(uint256).max;
    }
}
