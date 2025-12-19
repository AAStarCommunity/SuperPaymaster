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
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

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

        // Deploy Local EntryPoint
        EntryPoint entryPoint = new EntryPoint();
        address entryPointAddr = address(entryPoint);
        console.log("EntryPoint Local:", entryPointAddr);

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

        // 4. Wiring
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setReputationSource(address(repSystem), true);
        apnts.setSuperPaymasterAddress(address(paymaster));
        
        // Deposit some ETH to EntryPoint for Paymaster
        IEntryPoint(entryPointAddr).depositTo{value: 10 ether}(address(paymaster));

        // 5. Orchestrate Local Environment (Roles)
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        bytes32 ROLE_ENDUSER = keccak256("ENDUSER");

        // Mint GTokens for Deployer (Operator)
        gtoken.mint(deployer, 5000 ether);
        gtoken.approve(address(staking), 5000 ether);

        // Register Deployer as Operator
        bytes memory opData = abi.encode(
            Registry.CommunityRoleData("Local Operator", "local.eth", "http://localhost", "Local Test Hub", "", 10 ether)
        );
        registry.registerRole(ROLE_COMMUNITY, deployer, opData);

        // Register Alice as End User
        bytes memory aliceData = abi.encode("Alice Local Account");
        registry.registerRole(ROLE_ENDUSER, alice, aliceData);

        // Set an Entropy Factor for testing (0.5 resistance)
        repSystem.setEntropyFactor(deployer, 0.5 * 1e18);

        // Mint initial credit to Paymaster
        apnts.mint(address(paymaster), 1000 ether);

        vm.stopBroadcast();

        console.log("=== Local Beta Environment Ready ===");
        console.log("REGISTRY=", address(registry));
        console.log("PAYMASTER=", address(paymaster));
        console.log("APNTS=", address(apnts));
        console.log("REP_SYSTEM=", address(repSystem));
    }
}
