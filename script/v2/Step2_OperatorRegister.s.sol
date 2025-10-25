// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBTWithNFTBinding.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Step2_OperatorRegister
 * @notice V2测试流程 - 步骤2: Operator注册
 *
 * 功能：
 * 1. ⚠️ 确保 operator 已有 GToken（从 faucet 获取或已有余额）
 * 2. Operator stake GToken获得stGToken
 * 3. Operator部署xPNTs token
 * 4. Operator注册到SuperPaymaster
 *
 * IMPORTANT: This script does NOT mint GToken. Operator must obtain GToken from:
 * - Faucet: https://faucet.aastar.io/
 * - Or transfer from deployer
 */
contract Step2_OperatorRegister is Script {

    IERC20 gtoken;
    GTokenStaking gtokenStaking;
    SuperPaymasterV2 superPaymaster;
    xPNTsFactory xpntsFactory;
    MySBTWithNFTBinding mysbt;

    address operator;
    address operatorTreasury;

    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant LOCK_AMOUNT = 50 ether;

    function setUp() public {
        // 加载合约
        gtoken = IERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        xpntsFactory = xPNTsFactory(vm.envAddress("XPNTS_FACTORY_ADDRESS"));
        mysbt = MySBTWithNFTBinding(vm.envAddress("MYSBT_ADDRESS"));

        // Operator账户
        operator = vm.envAddress("OWNER2_ADDRESS");
        operatorTreasury = address(0x777);
    }

    function run() public {
        console.log("=== Step 2: Operator Registration ===\n");
        console.log("Operator address:");
        console.logAddress(operator);
        console.log("Operator treasury:");
        console.logAddress(operatorTreasury);

        // 1. ⚠️ IMPORTANT: Operator must already have GToken before running this script!
        //    Get GToken from: https://faucet.aastar.io/ or transfer from deployer
        //    Required amount: at least STAKE_AMOUNT (100 GT)

        uint256 operatorGTokenBalance = gtoken.balanceOf(operator);
        console.log("\n2.1 Checking operator's GToken balance...");
        console.log("    Operator GToken balance:");
        console.log(operatorGTokenBalance / 1e18, "GT");
        console.log("    Required for staking:");
        console.log(STAKE_AMOUNT / 1e18, "GT");
        require(operatorGTokenBalance >= STAKE_AMOUNT, "Insufficient GToken! Get from faucet: https://faucet.aastar.io/");

        // 2. Operator stake GToken
        console.log("\n2.2 Operator staking GToken...");
        vm.startBroadcast(vm.envUint("OWNER2_PRIVATE_KEY"));

        gtoken.approve(address(gtokenStaking), STAKE_AMOUNT);
        gtokenStaking.stake(STAKE_AMOUNT);

        uint256 stGTokenBalance = gtokenStaking.balanceOf(operator);
        console.log("    Staked:");
        console.log(STAKE_AMOUNT / 1e18, "GT");
        console.log("    Got stGToken:");
        console.log(stGTokenBalance / 1e18, "sGT");

        // 3. 部署xPNTs token
        console.log("\n2.3 Deploying operator's xPNTs token...");
        address xpntsAddr = xpntsFactory.deployxPNTsToken(
            "Test Community Points",
            "xTEST",
            "TestCommunity",
            "test.eth"
        );
        console.log("    xPNTs token deployed:");
        console.logAddress(xpntsAddr);

        // 4. 注册到SuperPaymaster
        console.log("\n2.4 Registering to SuperPaymaster...");
        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = address(mysbt);

        superPaymaster.registerOperator(
            LOCK_AMOUNT,
            supportedSBTs,
            xpntsAddr,
            operatorTreasury
        );
        console.log("    Locked stGToken:");
        console.log(LOCK_AMOUNT / 1e18, "sGT");
        console.log("    Registered successfully!");

        // 5. 验证注册
        console.log("\n2.5 Verifying registration...");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator);
        console.log("    Is registered:");
        console.log(account.stakedAt > 0);
        console.log("    Treasury:");
        console.log(account.treasury);
        console.log("    xPNTs token:");
        console.log(account.xPNTsToken);
        console.log("    Exchange rate:");
        console.log(account.exchangeRate / 1e18);

        require(account.treasury == operatorTreasury, "Treasury mismatch");
        require(account.xPNTsToken == xpntsAddr, "xPNTs token mismatch");

        console.log("\n[SUCCESS] Step 2 completed!");
        console.log("\nEnvironment variables to save:");
        console.log("OPERATOR_XPNTS_TOKEN_ADDRESS=", xpntsAddr);

        vm.stopBroadcast();
    }
}
