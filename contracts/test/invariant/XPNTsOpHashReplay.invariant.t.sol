// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "src/tokens/xPNTsToken.sol";
import {Clones} from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/**
 * @title XPNTsOpHashReplay_Invariant
 * @notice T-H2 (audit §6): machine-checks that a UserOp hash is settled AT MOST
 *         ONCE across BOTH settlement paths in xPNTsToken:
 *
 *             INV-3  for every opHash h:
 *                      successfulBurns[h] + successfulDebtRecords[h] <= 1
 *
 *         The contract enforces this via two cross-checked maps:
 *           burnFromWithOpHash:      reverts if usedOpHashes[h] || usedDebtHashes[h]
 *           recordDebtWithOpHash:    reverts if usedOpHashes[h] || usedDebtHashes[h]
 *
 *         A user must never be charged twice (burn) nor have debt recorded twice
 *         for the same op, and the burn/debt fallback paths must be mutually
 *         exclusive (P1-17 cross-path replay). The handler fuzzes both paths
 *         against a shared opHash pool and tallies how many times each hash was
 *         *successfully* settled; the invariant asserts no hash exceeds 1.
 */
contract XPNTsOpHashReplay_Invariant is StdInvariant, Test {
    XPNTsReplayHandler internal handler;

    function setUp() public {
        handler = new XPNTsReplayHandler();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.settleViaBurn.selector;
        selectors[1] = handler.settleViaDebt.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-3: no opHash was ever settled more than once.
    function invariant_opHashSettledAtMostOnce() public view {
        assertEq(handler.doubleSettleCount(), 0, "INV-3: an opHash settled more than once");
    }
}

contract XPNTsReplayHandler is Test {
    xPNTsToken public token;
    address public constant COMMUNITY_OWNER = address(0xC0);
    address public constant SP = address(0x5959);
    address public constant USER = address(0xABCD);

    uint256 public doubleSettleCount;
    // opHash => number of *successful* settlements (burn or debt). Must stay <= 1.
    mapping(bytes32 => uint256) public settledCount;

    bytes32[] internal _hashPool;

    constructor() {
        address impl = address(new xPNTsToken());
        token = xPNTsToken(Clones.clone(impl));
        token.initialize("xTest", "xT", COMMUNITY_OWNER, "Test", "test.eth", 1 ether);
        vm.prank(COMMUNITY_OWNER);
        token.setSuperPaymasterAddress(SP);

        // Give USER a large xPNTs balance so burns succeed on the merits.
        vm.prank(COMMUNITY_OWNER);
        token.mint(USER, 1_000_000 ether);

        // Small shared pool so burn/debt paths collide on the same opHash.
        for (uint256 i = 0; i < 4; i++) {
            _hashPool.push(keccak256(abi.encode("op", i)));
        }
    }

    function _pickHash(uint256 seed) internal view returns (bytes32) {
        return _hashPool[seed % _hashPool.length];
    }

    function settleViaBurn(uint256 hashSeed, uint256 amount) external {
        bytes32 h = _pickHash(hashSeed);
        amount = bound(amount, 1, 4_000 ether); // under maxSingleTxLimit
        vm.prank(SP);
        try token.burnFromWithOpHash(USER, amount, h) {
            settledCount[h] += 1;
            if (settledCount[h] > 1) doubleSettleCount++;
        } catch {
            // Expected when h already used via either path, or balance too low.
        }
    }

    function settleViaDebt(uint256 hashSeed, uint256 amount) external {
        bytes32 h = _pickHash(hashSeed);
        amount = bound(amount, 1, 4_000 ether);
        vm.prank(SP);
        try token.recordDebtWithOpHash(USER, amount, h) {
            settledCount[h] += 1;
            if (settledCount[h] > 1) doubleSettleCount++;
        } catch {
            // Expected when h already used via either path.
        }
    }
}
