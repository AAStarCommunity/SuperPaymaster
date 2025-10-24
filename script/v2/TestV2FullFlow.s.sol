// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title TestV2FullFlow
 * @notice 完整测试SuperPaymaster V2主流程
 * @dev 基于TEST-SCENARIO-1-V2-FULL-FLOW.md
 *
 * 流程：
 * 1. Operator准备：stake GToken → lock → register
 * 2. Operator充值：购买aPNTs → deposit
 * 3. User准备：mint SBT → 获取xPNTs
 * 4. User交易：模拟UserOp → 验证双重支付
 * 5. 验证：检查所有余额变化
 */
contract TestV2FullFlow is Script {

    // ====================================
    // 环境变量
    // ====================================
    address DEPLOYER;
    address OPERATOR;
    address USER;

    uint256 OPERATOR_KEY;

    // ====================================
    // 合约实例
    // ====================================
    MockERC20 gtoken;
    MockERC20 apntsToken;  // AAStar token
    GTokenStaking gtokenStaking;
    SuperPaymasterV2 superPaymaster;
    xPNTsFactory xpntsFactory;
    MySBT mysbt;

    xPNTsToken operatorXPNTs;

    // ====================================
    // 配置参数
    // ====================================
    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant LOCK_AMOUNT = 50 ether;
    uint256 constant APNTS_DEPOSIT = 1000 ether;
    uint256 constant USER_XPNTS = 500 ether;

    address operatorTreasury;
    address superPaymasterTreasury;

    function setUp() public {
        // 加载环境变量
        DEPLOYER = vm.envAddress("DEPLOYER_ADDRESS");
        OPERATOR = vm.envAddress("OWNER2_ADDRESS");
        OPERATOR_KEY = vm.envUint("OWNER2_PRIVATE_KEY");
        USER = address(0x999);  // 测试用户

        // 加载已部署的合约
        gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        xpntsFactory = xPNTsFactory(vm.envAddress("XPNTS_FACTORY_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));

        // 设置treasury地址
        operatorTreasury = address(0x777);
        superPaymasterTreasury = address(0x888);
    }

    function run() public {
        console.log("=== SuperPaymaster V2 Full Flow Test ===\n");

        // Phase 1: Setup (as deployer)
        console.log("[Phase 1] Setup & Configuration");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        setupContracts();
        vm.stopBroadcast();

        // Phase 2: Operator Registration & Deposit
        console.log("\n[Phase 2] Operator Registration & Deposit");
        vm.startBroadcast(OPERATOR_KEY);
        operatorFlow();
        vm.stopBroadcast();

        // Phase 3: User Preparation
        console.log("\n[Phase 3] User Preparation");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        userPreparation();
        vm.stopBroadcast();

        // Phase 4: User Transaction Simulation
        console.log("\n[Phase 4] User Transaction Simulation");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        userTransaction();
        vm.stopBroadcast();

        // Phase 5: Verification
        console.log("\n[Phase 5] Final Verification");
        verification();

        console.log("\n=== Test Complete ===");
    }

    function setupContracts() internal {
        console.log("  1.1 Deploying aPNTs token (AAStar token)...");
        apntsToken = new MockERC20("AAStar Points", "aPNTs", 18);
        console.log("      aPNTs token:", address(apntsToken));

        console.log("  1.2 Configuring SuperPaymaster...");
        superPaymaster.setAPNTsToken(address(apntsToken));
        superPaymaster.setSuperPaymasterTreasury(superPaymasterTreasury);
        console.log("      Treasury:", superPaymasterTreasury);

        console.log("  1.3 Minting tokens to operator...");
        // Mint GToken for staking
        gtoken.mint(OPERATOR, STAKE_AMOUNT);
        // Mint aPNTs for deposit
        apntsToken.mint(OPERATOR, APNTS_DEPOSIT * 2);  // 2倍，留一些
        console.log("      GToken to operator:", STAKE_AMOUNT / 1e18, "GT");
        console.log("      aPNTs to operator:", (APNTS_DEPOSIT * 2) / 1e18, "aPNTs");
    }

    function operatorFlow() internal {
        console.log("  2.1 Operator stakes GToken...");
        gtoken.approve(address(gtokenStaking), STAKE_AMOUNT);
        gtokenStaking.stake(STAKE_AMOUNT);
        uint256 sGTokenBalance = gtokenStaking.balanceOf(OPERATOR);
        console.log("      Staked:", STAKE_AMOUNT / 1e18, "GT");
        console.log("      Got sGToken:", sGTokenBalance / 1e18, "sGT");

        console.log("  2.2 Deploying operator's xPNTs token...");
        address xpntsAddr = xpntsFactory.deployxPNTsToken(
            "Test Community Points",
            "xTEST",
            "TestCommunity",
            "test.eth"
        );
        operatorXPNTs = xPNTsToken(xpntsAddr);
        console.log("      xPNTs token:", xpntsAddr);

        console.log("  2.3 Operator registers to SuperPaymaster...");
        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = address(mysbt);

        superPaymaster.registerOperator(
            LOCK_AMOUNT,
            supportedSBTs,
            address(operatorXPNTs),
            operatorTreasury
        );
        console.log("      Locked sGToken:", LOCK_AMOUNT / 1e18, "sGT");
        console.log("      Operator treasury:", operatorTreasury);

        console.log("  2.4 Operator deposits aPNTs...");
        apntsToken.approve(address(superPaymaster), APNTS_DEPOSIT);
        superPaymaster.depositAPNTs(APNTS_DEPOSIT);

        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(OPERATOR);
        console.log("      Deposited aPNTs:", APNTS_DEPOSIT / 1e18, "aPNTs");
        console.log("      aPNTs balance:", account.aPNTsBalance / 1e18, "aPNTs");
    }

    function userPreparation() internal {
        console.log("  3.1 User mints SBT...");
        // User needs to stake first
        gtoken.mint(USER, 1 ether);
        vm.startPrank(USER);
        gtoken.approve(address(gtokenStaking), 0.1 ether);
        gtokenStaking.stake(0.1 ether);
        gtoken.approve(address(mysbt), 0.1 ether);
        uint256 tokenId = mysbt.mintSBT(OPERATOR); // Use operator as community
        vm.stopPrank();

        console.log("      SBT minted, tokenId:", tokenId);

        console.log("  3.2 User gets xPNTs...");
        // Operator gives xPNTs to user (or user buys from market)
        vm.startPrank(OPERATOR);
        operatorXPNTs.mint(USER, USER_XPNTS);
        vm.stopPrank();
        console.log("      User xPNTs:", USER_XPNTS / 1e18, "xTEST");
    }

    function userTransaction() internal {
        console.log("  4.1 Simulating user transaction...");

        // 模拟gas cost: 0.001 ETH
        uint256 gasCost = 0.001 ether;

        // 计算aPNTs和xPNTs费用
        // 简化计算：假设gasToUSDRate = 3000 USD/ETH, aPNTsPriceUSD = 0.02 USD
        // gasCostUSD = 0.001 * 3000 = 3 USD
        // with 2% fee = 3.06 USD
        // aPNTs = 3.06 / 0.02 = 153 aPNTs
        uint256 aPNTsCost = 153 ether;
        uint256 xPNTsCost = aPNTsCost;  // 1:1 exchange rate

        console.log("      Gas cost:", gasCost);
        console.log("      aPNTs cost:", aPNTsCost / 1e18, "aPNTs");
        console.log("      xPNTs cost:", xPNTsCost / 1e18, "xTEST");

        console.log("  4.2 User approves xPNTs (pre-approve pattern)...");
        vm.startPrank(USER);
        operatorXPNTs.approve(address(superPaymaster), xPNTsCost);
        vm.stopPrank();

        console.log("  4.3 Simulating validatePaymasterUserOp...");
        // 记录交易前余额
        uint256 userXPNTsBefore = operatorXPNTs.balanceOf(USER);
        uint256 treasuryXPNTsBefore = operatorXPNTs.balanceOf(operatorTreasury);

        SuperPaymasterV2.OperatorAccount memory accountBefore = superPaymaster.getOperatorAccount(OPERATOR);
        uint256 treasuryAPNTsBefore = superPaymaster.treasuryAPNTsBalance();

        console.log("      [BEFORE]");
        console.log("        User xPNTs:", userXPNTsBefore / 1e18);
        console.log("        Operator treasury xPNTs:", treasuryXPNTsBefore / 1e18);
        console.log("        Operator aPNTs balance:", accountBefore.aPNTsBalance / 1e18);
        console.log("        SuperPaymaster treasury aPNTs:", treasuryAPNTsBefore / 1e18);

        // 模拟EntryPoint调用validatePaymasterUserOp
        // 注意：这里需要mock EntryPoint的调用，实际部署后需要真实EntryPoint
        console.log("      [SIMULATE] EntryPoint calls validatePaymasterUserOp...");
        console.log("        (Note: Needs actual EntryPoint integration for real test)");

        // 手动模拟双重支付
        vm.startPrank(USER);
        operatorXPNTs.transfer(operatorTreasury, xPNTsCost);
        vm.stopPrank();

        // 模拟内部记账
        // (实际应由validatePaymasterUserOp完成)
        console.log("        Simulating internal aPNTs accounting...");

        // 记录交易后余额
        uint256 userXPNTsAfter = operatorXPNTs.balanceOf(USER);
        uint256 treasuryXPNTsAfter = operatorXPNTs.balanceOf(operatorTreasury);

        console.log("      [AFTER]");
        console.log("        User xPNTs:", userXPNTsAfter / 1e18);
        console.log("        Operator treasury xPNTs:", treasuryXPNTsAfter / 1e18);
        console.log("        xPNTs transferred:", (treasuryXPNTsAfter - treasuryXPNTsBefore) / 1e18);
    }

    function verification() internal view {
        console.log("  5.1 Checking operator account...");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(OPERATOR);
        console.log("      Operator registered:", account.stakedAt > 0);
        console.log("      aPNTs balance:", account.aPNTsBalance / 1e18, "aPNTs");
        console.log("      Treasury:", account.treasury);
        console.log("      xPNTs token:", account.xPNTsToken);
        console.log("      Exchange rate:", account.exchangeRate / 1e18);

        console.log("  5.2 Checking user assets...");
        console.log("      User SBT count:", mysbt.balanceOf(USER));
        console.log("      User xPNTs:", operatorXPNTs.balanceOf(USER) / 1e18, "xTEST");

        console.log("  5.3 Checking treasuries...");
        console.log("      Operator treasury xPNTs:", operatorXPNTs.balanceOf(operatorTreasury) / 1e18, "xTEST");
        console.log("      SuperPaymaster treasury aPNTs (internal):", superPaymaster.treasuryAPNTsBalance() / 1e18, "aPNTs");

        console.log("  5.4 Checking aPNTs distribution...");
        uint256 contractAPNTs = apntsToken.balanceOf(address(superPaymaster));
        uint256 operatorAPNTs = account.aPNTsBalance;
        uint256 treasuryAPNTs = superPaymaster.treasuryAPNTsBalance();
        console.log("      SuperPaymaster contract holds:", contractAPNTs / 1e18, "aPNTs");
        console.log("      Operator balance (internal):", operatorAPNTs / 1e18, "aPNTs");
        console.log("      Treasury balance (internal):", treasuryAPNTs / 1e18, "aPNTs");
        console.log("      Sum equals contract:", (operatorAPNTs + treasuryAPNTs) == contractAPNTs);
    }
}
