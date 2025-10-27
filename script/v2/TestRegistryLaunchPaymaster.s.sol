// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/Registry.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBTWithNFTBinding.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestRegistryLaunchPaymaster
 * @notice 完整测试 Registry 注册 → Launch Paymaster 流程
 *
 * ⚠️ IMPORTANT: This test requires pre-funded accounts with GToken:
 * - COMMUNITY_AOA_ADDRESS must have at least 200 GT (get from faucet: https://faucet.aastar.io/)
 * - COMMUNITY_SUPER_ADDRESS must have at least 200 GT (get from faucet)
 * - USER_ADDRESS must have at least 100 GT (get from faucet or transfer)
 *
 * 测试流程：
 * 1. Community 注册到 Registry（AOA + Super 两种模式）
 * 2. 验证注册状态
 * 3. Launch Paymaster（Operator 注册到 SuperPaymaster）
 * 4. 验证 Paymaster 运行状态
 * 5. 测试用户交易流程
 */
contract TestRegistryLaunchPaymaster is Script {

    // Contracts
    IERC20 gtoken;
    GTokenStaking gtokenStaking;
    Registry registry;
    SuperPaymasterV2 superPaymaster;
    xPNTsFactory xpntsFactory;
    MySBTWithNFTBinding mysbt;

    // Test accounts
    address deployer;
    address communityAOA;       // AOA mode community
    address communitySuper;     // Super mode community
    address user;

    // Constants
    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant LOCK_AOA = 50 ether;
    uint256 constant LOCK_SUPER = 30 ether;

    function setUp() public {
        // Load deployed contracts
        gtoken = IERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        registry = Registry(vm.envAddress("REGISTRY_ADDRESS"));
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        xpntsFactory = xPNTsFactory(vm.envAddress("XPNTS_FACTORY_ADDRESS"));
        mysbt = MySBTWithNFTBinding(vm.envAddress("MYSBT_ADDRESS"));

        // Test accounts
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        communityAOA = vm.envAddress("COMMUNITY_AOA_ADDRESS");
        communitySuper = vm.envAddress("COMMUNITY_SUPER_ADDRESS");
        user = vm.envAddress("USER_ADDRESS");
    }

    function run() public {
        console.log("=== Registry Launch Paymaster Flow Test ===\n");

        // Phase 1: 准备资源
        _prepareResources();

        // Phase 2: AOA Mode 测试
        _testAOAMode();

        // Phase 3: Super Mode 测试
        _testSuperMode();

        // Phase 4: 综合验证
        _verifyAll();

        console.log("\n[SUCCESS] All tests passed!");
    }

    // ====================================
    // Phase 1: 准备资源
    // ====================================

    function _prepareResources() private view {
        console.log("=== Phase 1: Prepare Resources ===\n");

        // Check GToken balances for all test accounts
        uint256 balanceAOA = gtoken.balanceOf(communityAOA);
        uint256 balanceSuper = gtoken.balanceOf(communitySuper);
        uint256 balanceUser = gtoken.balanceOf(user);

        console.log("Checking GToken balances:");
        console.log("  - Community AOA:");
        console.logUint(balanceAOA / 1e18);
        console.log("  - Community Super:");
        console.logUint(balanceSuper / 1e18);
        console.log("  - User:");
        console.logUint(balanceUser / 1e18);

        require(balanceAOA >= STAKE_AMOUNT * 2, "Community AOA needs at least 200 GT! Get from faucet");
        require(balanceSuper >= STAKE_AMOUNT * 2, "Community Super needs at least 200 GT! Get from faucet");
        require(balanceUser >= STAKE_AMOUNT, "User needs at least 100 GT! Get from faucet");

        console.log("\n[DONE] Phase 1\n");
    }

    // ====================================
    // Phase 2: AOA Mode 测试
    // ====================================

    function _testAOAMode() private {
        console.log("=== Phase 2: Test AOA Mode ===\n");

        vm.startBroadcast(vm.envUint("COMMUNITY_AOA_PRIVATE_KEY"));

        // 2.1 Stake GToken
        console.log("2.1 Staking GToken...");
        gtoken.approve(address(gtokenStaking), STAKE_AMOUNT);
        gtokenStaking.stake(STAKE_AMOUNT);

        uint256 stGTokenBalance = gtokenStaking.balanceOf(communityAOA);
        console.log("    Staked:");
        console.log(STAKE_AMOUNT / 1e18, "GT");
        console.log("    Got stGToken:");
        console.log(stGTokenBalance / 1e18, "stGT");

        // 2.2 Deploy xPNTs
        console.log("\n2.2 Deploying xPNTs token...");
        address xpntsAOA = xpntsFactory.deployxPNTsToken(
            "AOA Community Points",
            "xAOA",
            "AOACommunity",
            "aoa.eth"
        );
        console.log("    xPNTs deployed:");
        console.logAddress(xpntsAOA);

        // 2.3 Register to Registry (AOA mode)
        console.log("\n2.3 Registering to Registry (AOA mode)...");

        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = address(mysbt);

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AOA Community",
            ensName: "aoa.eth",
            description: "Test AOA mode community",
            website: "https://aoa.test",
            logoURI: "ipfs://aoa-logo",
            twitterHandle: "@aoa_community",
            githubOrg: "aoa-org",
            telegramGroup: "https://t.me/aoa_group",
            xPNTsToken: xpntsAOA,
            supportedSBTs: supportedSBTs,
            mode: Registry.PaymasterMode.INDEPENDENT,
            nodeType: Registry.NodeType.PAYMASTER_AOA,  // v2.1: AOA node type
            paymasterAddress: address(0),  // No SuperPaymaster for AOA
            community: address(0),  // Will be set by Registry
            registeredAt: 0,  // Will be set by Registry
            lastUpdatedAt: 0,  // Will be set by Registry
            isActive: false,  // Will be set by Registry
            memberCount: 0
        });

        registry.registerCommunity(profile, LOCK_AOA);

        console.log("    Locked stGToken:");
        console.log(LOCK_AOA / 1e18, "stGT");
        console.log("    Registered to Registry!");

        // 2.4 Verify registration
        console.log("\n2.4 Verifying AOA mode registration...");
        Registry.CommunityProfile memory registered = registry.getCommunityProfile(communityAOA);
        require(bytes(registered.name).length > 0, "Registration failed");
        require(registered.mode == Registry.PaymasterMode.INDEPENDENT, "Mode mismatch");
        require(registered.isActive, "Not active");
        console.log("    [OK] Community registered");
        console.log("    [OK] Mode: AOA (INDEPENDENT)");
        console.log("    [OK] Active: true");

        vm.stopBroadcast();

        console.log("\n[DONE] Phase 2: AOA Mode\n");
    }

    // ====================================
    // Phase 3: Super Mode 测试
    // ====================================

    function _testSuperMode() private {
        console.log("=== Phase 3: Test Super Mode ===\n");

        vm.startBroadcast(vm.envUint("COMMUNITY_SUPER_PRIVATE_KEY"));

        // 3.1 Stake GToken
        console.log("3.1 Staking GToken...");
        gtoken.approve(address(gtokenStaking), STAKE_AMOUNT);
        gtokenStaking.stake(STAKE_AMOUNT);

        uint256 stGTokenBalance = gtokenStaking.balanceOf(communitySuper);
        console.log("    Staked:");
        console.log(STAKE_AMOUNT / 1e18, "GT");
        console.log("    Got stGToken:");
        console.log(stGTokenBalance / 1e18, "stGT");

        // 3.2 Deploy xPNTs
        console.log("\n3.2 Deploying xPNTs token...");
        address xpntsSuper = xpntsFactory.deployxPNTsToken(
            "Super Community Points",
            "xSUPER",
            "SuperCommunity",
            "super.eth"
        );
        console.log("    xPNTs deployed:");
        console.logAddress(xpntsSuper);

        // 3.3 Register to SuperPaymaster FIRST
        console.log("\n3.3 Registering to SuperPaymaster...");

        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = address(mysbt);

        superPaymaster.registerOperator(
            LOCK_SUPER,
            supportedSBTs,
            xpntsSuper,
            communitySuper  // treasury
        );

        console.log("    Locked stGToken:");
        console.log(LOCK_SUPER / 1e18, "stGT");
        console.log("    Registered to SuperPaymaster!");

        // 3.4 Register to Registry (Super mode, stGTokenAmount=0)
        console.log("\n3.4 Registering to Registry (Super mode)...");

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "Super Community",
            ensName: "super.eth",
            description: "Test Super mode community",
            website: "https://super.test",
            logoURI: "ipfs://super-logo",
            twitterHandle: "@super_community",
            githubOrg: "super-org",
            telegramGroup: "https://t.me/super_group",
            xPNTsToken: xpntsSuper,
            supportedSBTs: supportedSBTs,
            mode: Registry.PaymasterMode.SUPER,
            nodeType: Registry.NodeType.PAYMASTER_SUPER,  // v2.1: Super node type
            paymasterAddress: address(superPaymaster),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            memberCount: 0
        });

        // Super mode: use 0 because already locked via SuperPaymaster
        registry.registerCommunity(profile, 0);

        console.log("    Registered to Registry (reusing SuperPaymaster lock)");

        // 3.5 Verify registration
        console.log("\n3.5 Verifying Super mode registration...");
        Registry.CommunityProfile memory registered = registry.getCommunityProfile(communitySuper);
        require(bytes(registered.name).length > 0, "Registration failed");
        require(registered.mode == Registry.PaymasterMode.SUPER, "Mode mismatch");
        require(registered.paymasterAddress == address(superPaymaster), "Paymaster mismatch");
        require(registered.isActive, "Not active");
        console.log("    [OK] Community registered");
        console.log("    [OK] Mode: SUPER");
        console.log("    [OK] Paymaster:", address(superPaymaster));
        console.log("    [OK] Active: true");

        vm.stopBroadcast();

        console.log("\n[DONE] Phase 3: Super Mode\n");
    }

    // ====================================
    // Phase 4: 综合验证
    // ====================================

    function _verifyAll() private view {
        console.log("=== Phase 4: Comprehensive Verification ===\n");

        // 4.1 Registry state
        console.log("4.1 Registry State:");
        uint256 totalCommunities = registry.getCommunityCount();
        console.log("    Total communities:");
        console.logUint(totalCommunities);
        require(totalCommunities >= 2, "Missing communities");

        // 4.2 AOA mode verification
        console.log("\n4.2 AOA Mode Verification:");
        Registry.CommunityProfile memory aoaProfile = registry.getCommunityProfile(communityAOA);
        console.log("    Name:");
        console.log(aoaProfile.name);
        console.log("    Mode:");
        console.log(aoaProfile.mode == Registry.PaymasterMode.INDEPENDENT ? "AOA" : "SUPER");
        console.log("    Active:");
        console.log(aoaProfile.isActive);
        console.log("    xPNTs Token:");
        console.log(aoaProfile.xPNTsToken);

        // 4.3 Super mode verification
        console.log("\n4.3 Super Mode Verification:");
        Registry.CommunityProfile memory superProfile = registry.getCommunityProfile(communitySuper);
        console.log("    Name:");
        console.log(superProfile.name);
        console.log("    Mode:");
        console.log(superProfile.mode == Registry.PaymasterMode.SUPER ? "SUPER" : "AOA");
        console.log("    Paymaster:");
        console.log(superProfile.paymasterAddress);
        console.log("    Active:");
        console.log(superProfile.isActive);
        console.log("    xPNTs Token:");
        console.log(superProfile.xPNTsToken);

        // 4.4 SuperPaymaster state
        console.log("\n4.4 SuperPaymaster State:");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(communitySuper);
        console.log("    Operator registered:");
        console.log(account.stakedAt > 0);
        console.log("    Locked stGToken:");
        console.log(account.stGTokenLocked / 1e18, "stGT");
        console.log("    xPNTs token:");
        console.log(account.xPNTsToken);
        console.log("    Treasury:");
        console.log(account.treasury);

        console.log("\n[DONE] Phase 4: All Verified!\n");
    }
}
