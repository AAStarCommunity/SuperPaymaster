// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBTWithNFTBinding.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Step4_UserPrep
 * @notice V2测试流程 - 步骤4: 用户准备
 *
 * 功能：
 * 1. ⚠️ 确保 user 已有 GToken（从 faucet 获取或从 deployer 转账）
 * 2. 用户mint SBT (需要先stake GToken)
 * 3. Operator给用户mint xPNTs
 * 4. 验证用户资产
 *
 * IMPORTANT: This script does NOT mint GToken. User must obtain GToken from:
 * - Faucet: https://faucet.aastar.io/
 * - Or transfer from deployer (at least 1 GT required)
 */
contract Step4_UserPrep is Script {

    IERC20 gtoken;
    GTokenStaking gtokenStaking;
    MySBTWithNFTBinding mysbt;
    xPNTsToken operatorXPNTs;

    address user;
    uint256 userKey;
    address operator;

    uint256 constant USER_XPNTS = 500 ether;

    function setUp() public {
        // 加载合约
        gtoken = IERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        mysbt = MySBTWithNFTBinding(vm.envAddress("MYSBT_ADDRESS"));
        operatorXPNTs = xPNTsToken(vm.envAddress("OPERATOR_XPNTS_TOKEN_ADDRESS"));

        // 账户 - 使用测试私钥生成用户地址
        userKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        user = vm.addr(userKey);
        operator = vm.envAddress("OWNER2_ADDRESS");
    }

    function run() public {
        console.log("=== Step 4: User Preparation ===\n");
        console.log("User address:");
        console.logAddress(user);

        // 1. User mint SBT
        console.log("\n4.1 User minting SBT...");

        // ⚠️ Check user's GToken balance
        uint256 userGTokenBalance = gtoken.balanceOf(user);
        console.log("    User GToken balance:");
        console.logUint(userGTokenBalance / 1e18);
        console.log("    Required (stake + fee):");
        // console.logUint(0.3 ether / 1e18); // Skip: fractional division
        require(userGTokenBalance >= 1 ether, "Insufficient GToken! Get from faucet: https://faucet.aastar.io/");

        // User stake GToken并mint SBT
        vm.startBroadcast(userKey);

        // Stake GToken first
        gtoken.approve(address(gtokenStaking), 0.3 ether); // minLockAmount + mintFee
        gtokenStaking.stake(0.3 ether);
        console.log("    User staked 0.3 GToken");

        // Approve GToken for mintFee burn
        gtoken.approve(address(mysbt), 0.1 ether);

        // Mint SBT with community address (using operator as community for testing)
        mysbt.mintSBT(operator);
        console.log("    User minted SBT for community:");
        console.logAddress(operator);

        vm.stopBroadcast();

        // Get tokenId using userCommunityToken mapping
        uint256 tokenId = mysbt.userCommunityToken(user, operator);
        console.log("    SBT tokenId:");
        console.logUint(tokenId);

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

        console.log("    User SBT count:");
        console.logUint(userSBTCount);
        console.log("    User xPNTs balance:");
        console.log(userXPNTs / 1e18, "xTEST");

        require(userSBTCount > 0, "User has no SBT");
        require(userXPNTs == USER_XPNTS, "xPNTs balance mismatch");

        console.log("\n[SUCCESS] Step 4 completed!");
        console.log("\nUser is now ready to:");
        console.log("- Has SBT for validation");
        console.log("- Has xPNTs for payment");
    }
}
