// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { SimpleAccountFactory } from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
// SimpleAccountFactory accountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddr));
// address aliceAccount = accountFactory.createAccount(alice, 0);
// console.log("Alice AA Account:", aliceAccount);

// Minimal Mock for local wiring
contract MockEntryPoint is IStakeManager {
    function depositTo(address account) external payable {
        // Just accept funds
    }
    function getUserOpHash(PackedUserOperation calldata) external view returns (bytes32) {
        return keccak256("mock_hash");
    }
    function balanceOf(address account) external view returns (uint256) {
        return 0;
    }
    // Implement other IStakeManager if needed
    function getDepositInfo(address account) external view returns (DepositInfo memory info) {}
    function balanceAt(address account, uint256 blockNumber) external view returns (uint256) {}
    function addStake(uint32 unstakeDelaySec) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable withdrawAddress) external {}
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {}
}

/**
 * @title DeployV3FullLocal
 * @notice Dedicated Local Deployment for Anvil with automatic funding and role orchestration.
 */
contract DeployV3FullLocal is Script {
    function run() external {
        uint256 deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil #0
        uint256 alicePK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // Anvil #1
        address deployer = vm.addr(deployerPK);
        address alice = vm.addr(alicePK);

        // 0. Fund accounts heavily on local
        vm.deal(deployer, 1000 ether);
        vm.deal(alice, 1000 ether);

        vm.startBroadcast(deployerPK);

        // Deploy Local MockEntryPoint for local orchestration
        MockEntryPoint entryPoint = new MockEntryPoint();
        address entryPointAddr = address(entryPoint);
        console.log("MockEntryPoint Local:", entryPointAddr);

        address priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

        // 1. Deploy Foundation
        GToken gtoken = new GToken(21_000_000 * 1e18);
        GTokenStaking staking = new GTokenStaking(address(gtoken), deployer);

        uint256 deployerNonce = vm.getNonce(deployer);
        address precomputedSBT = vm.computeCreateAddress(deployer, deployerNonce + 1);

        Registry registry = new Registry(address(gtoken), address(staking), precomputedSBT);
        MySBT mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);
        
        // 2. Reputation & Token
        ReputationSystemV3 repSystem = new ReputationSystemV3(address(registry));
        xPNTsToken apnts = new xPNTsToken("aPNTs", "aPNTs", deployer, "LocalHub", "local.eth", 1e18);

        // 3. SuperPaymaster
        SuperPaymasterV3 paymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            address(apnts),
            priceFeedAddr,
            deployer
        );

        // 3.1 BLS Aggregator Setup (Requested Threshold: 3)
        BLSAggregatorV3 aggregator = new BLSAggregatorV3(address(registry), address(paymaster), address(0));
        aggregator.setThreshold(3);
        registry.setBLSAggregator(address(aggregator));
        console.log("BLSAggregator Local (Threshold=3):", address(aggregator));

        // 3.2 DVT Validator Setup
        DVTValidatorV3 dvt = new DVTValidatorV3(address(registry));
        dvt.setBLSAggregator(address(aggregator));
        console.log("DVTValidator Local:", address(dvt));

        // 3.3 xPNTs Factory Setup
        xPNTsFactory factory = new xPNTsFactory(address(paymaster), address(registry));
        console.log("xPNTsFactory Local:", address(factory));

        // 4. AA Setup (SimpleAccountFactory)
        SimpleAccountFactory accountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddr));
        address aliceAccount = address(accountFactory.createAccount(alice, 0));
        console.log("Alice AA Account:", aliceAccount);
        vm.deal(aliceAccount, 10 ether); // Fund Alice's AA account

        // 5. Wiring
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setReputationSource(address(repSystem), true);
        apnts.setSuperPaymasterAddress(address(paymaster));
        
        // 5.1 Set role exit fees (since _initRole doesn't call setRoleExitFee during construction)
        bytes32 ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
        bytes32 ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
        bytes32 ROLE_ANODE = keccak256("ANODE");
        bytes32 ROLE_KMS = keccak256("KMS");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
        
        staking.setRoleExitFee(ROLE_PAYMASTER_AOA, 1000, 1 ether);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 1000, 2 ether);
        staking.setRoleExitFee(ROLE_ANODE, 1000, 1 ether);
        staking.setRoleExitFee(ROLE_KMS, 1000, 5 ether);
        staking.setRoleExitFee(ROLE_COMMUNITY, 1000, 0.5 ether);
        staking.setRoleExitFee(ROLE_ENDUSER, 1000, 0.05 ether);
        
        // Deposit some ETH to EntryPoint for Paymaster
        IEntryPoint(entryPointAddr).depositTo{value: 10 ether}(address(paymaster));

        // 6. Orchestrate Local Environment (Roles)
        // (ROLE_COMMUNITY and ROLE_ENDUSER already defined above)

        // Mint GTokens for Deployer (Operator)
        gtoken.mint(deployer, 5000 ether);
        gtoken.approve(address(staking), 5000 ether);

        // Register Deployer as Operator
        bytes memory opData = abi.encode(
            Registry.CommunityRoleData("Local Operator", "local.eth", "http://localhost", "Local Test Hub", "", 30 ether)
        );
        registry.registerRole(ROLE_COMMUNITY, deployer, opData);

        // Mint GTokens for Alice's AA Account (not Alice EOA)
        // Because registerRole uses aliceAccount as payer
        // NOTE: Commented out because AA account can't directly approve in deployment script
        // Test scripts will handle Alice registration with proper AA transaction flow
        // gtoken.mint(aliceAccount, 1000 ether);
        
        // --- Skip Alice registration in deployment, will be done in test scripts ---
        // vm.stopBroadcast();
        // vm.prank(aliceAccount);
        // gtoken.approve(address(staking), 1000 ether);
        // vm.startBroadcast(deployerPK);
        
        // Encode EndUserRoleData: LINK TO DEPLOYER AS COMMUNITY
        // bytes memory aliceData = abi.encode(Registry.EndUserRoleData({
        //     account: aliceAccount, 
        //     community: deployer,   // Deployer is the operator/community
        //     avatarURI: "ipfs://alice", 
        //     ensName: "alice.local.eth", 
        //     stakeAmount: 0        // Min stake is used if 0
        // }));
        
        // Register AliceRole via Registry (Single Entrypoint)
        // registry.registerRole(ROLE_ENDUSER, aliceAccount, aliceData);


        // Set an Entropy Factor for testing (0.5 resistance)
        repSystem.setEntropyFactor(deployer, 0.5 * 1e18);

        // Mint initial credit to Paymaster
        apnts.mint(address(paymaster), 1000 ether);

        vm.stopBroadcast();
        
        // Deploy PaymasterV4 (after stopBroadcast to avoid nonce issues)
        vm.startBroadcast(deployerPK);
        PaymasterV4 paymasterV4 = new PaymasterV4(
            entryPointAddr,
            deployer,
            deployer, // treasury
            priceFeedAddr, // ethUsdPriceFeed
            1000, // serviceFeeRate (10%)
            1 ether, // maxGasCostCap
            address(factory) // xpntsFactory
        );
        vm.stopBroadcast();

        // ----------------------------------------
        // Generate config.json (For Regression Scripts)
        // ----------------------------------------
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(paymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(0)); // Placeholder if needed
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(factory));
        vm.serializeAddress(jsonObj, "paymasterV4", address(paymasterV4)); // New V4
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);

        vm.writeFile("script/v3/config.json", finalJson);
        console.log("Generated script/v3/config.json");

        console.log("=== Local Beta Environment Ready ===");
        console.log("REGISTRY=", address(registry));
        console.log("PAYMASTER=", address(paymaster));
        console.log("PAYMASTER_V4=", address(paymasterV4));
    }
}
