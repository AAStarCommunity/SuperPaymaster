// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/v2/core/GTokenStaking.sol";
import "../../src/v2/tokens/xPNTsToken.sol";
import "../../src/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title Step4_UserPrep
 * @notice V2测试流程 - 步骤4: 用户准备
 *
 * 功能：
 * 1. 用户mint SBT (需要先stake GToken)
 * 2. Operator给用户mint xPNTs
 * 3. 验证用户资产
 */
contract Step4_UserPrep is Script {

    MockERC20 gtoken;
    GTokenStaking gtokenStaking;
    MySBT mysbt;
    xPNTsToken operatorXPNTs;

    address user;
    address operator;

    uint256 constant USER_XPNTS = 500 ether;

    function setUp() public {
        // 加载合约
        gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));
        operatorXPNTs = xPNTsToken(vm.envAddress("OPERATOR_XPNTS_TOKEN_ADDRESS"));

        // 账户
        user = address(0x999);
        operator = vm.envAddress("OWNER2_ADDRESS");
    }

    function run() public {
        console.log("=== Step 4: User Preparation ===\n");
        console.log("User address:", user);

        // 1. User mint SBT
        console.log("\n4.1 User minting SBT...");

        // Deployer给user mint一些GToken用于stake
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gtoken.mint(user, 1 ether);
        console.log("    Minted 1 GToken to user");
        vm.stopBroadcast();

        // User stake GToken并mint SBT
        vm.startBroadcast(user);
        gtoken.approve(address(gtokenStaking), 0.1 ether);
        gtokenStaking.stake(0.1 ether);
        console.log("    User staked 0.1 GToken");

        gtokenStaking.approve(address(mysbt), 0.1 ether);
        mysbt.mintSBT();
        console.log("    User minted SBT");

        uint256 tokenId = mysbt.tokenOfOwnerByIndex(user, 0);
        console.log("    SBT tokenId:", tokenId);
        vm.stopPrank();

        // 2. Operator给user mint xPNTs
        console.log("\n4.2 Operator minting xPNTs to user...");
        vm.startBroadcast(vm.envUint("OWNER2_PRIVATE_KEY"));
        operatorXPNTs.mint(user, USER_XPNTS);
        console.log("    Minted", USER_XPNTS / 1e18, "xTEST to user");
        vm.stopBroadcast();

        // 3. 验证
        console.log("\n4.3 Verifying user assets...");
        uint256 userSBTCount = mysbt.balanceOf(user);
        uint256 userXPNTs = operatorXPNTs.balanceOf(user);

        console.log("    User SBT count:", userSBTCount);
        console.log("    User xPNTs balance:", userXPNTs / 1e18, "xTEST");

        require(userSBTCount > 0, "User has no SBT");
        require(userXPNTs == USER_XPNTS, "xPNTs balance mismatch");

        console.log("\n[SUCCESS] Step 4 completed!");
        console.log("\nUser is now ready to:");
        console.log("- Has SBT for validation");
        console.log("- Has xPNTs for payment");
    }
}
