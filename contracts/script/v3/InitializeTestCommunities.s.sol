// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/GToken.sol";

contract InitializeTestCommunities is Script {
    function run() external {
        string memory root = vm.projectRoot();
        string memory network = vm.envOr("NETWORK", string("anvil"));
        string memory configPath = string.concat(root, "/deployments/config.", network, ".json");
        string memory json = vm.readFile(configPath);

        address registryAddr = vm.parseJsonAddress(json, ".registry");
        address spAddr = vm.parseJsonAddress(json, ".superPaymaster");
        address factoryAddr = vm.parseJsonAddress(json, ".xPNTsFactory");
        address aPNTsAddr = vm.parseJsonAddress(json, ".aPNTs");
        address gTokenAddr = vm.parseJsonAddress(json, ".gToken");

        Registry registry = Registry(registryAddr);
        SuperPaymaster sp = SuperPaymaster(payable(spAddr));
        xPNTsFactory factory = xPNTsFactory(factoryAddr);
        GToken gToken = GToken(gTokenAddr);

        uint256 jasonPK = vm.envUint("PRIVATE_KEY");
        uint256 anniPK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        address jason = vm.addr(jasonPK);
        address anni = vm.addr(anniPK);

        address staking = address(registry.GTOKEN_STAKING());

        // --- 1. 给 Jason 和 Anni 充钱 (Anvil Only) ---
        // 在 Anvil 下，Deployer 通常也是 GToken 的 Owner
        vm.startBroadcast(jasonPK);
        try gToken.mint(jason, 1000 ether) {} catch {}
        try gToken.mint(anni, 1000 ether) {} catch {}
        
        // --- 2. 初始化 AAStar (Jason) ---
        console.log("Registering AAStar community...");
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "aastar.io",
            description: "AAStar Community - Empower Community! Twitter: https://X.com/AAStarCommunity",
            logoURI: "ipfs://aastar-logo",
            stakeAmount: 30 ether
        });
        
        gToken.approve(staking, 50 ether);
        if (!registry.hasRole(registry.ROLE_COMMUNITY(), jason)) {
            registry.registerRole(registry.ROLE_COMMUNITY(), jason, abi.encode(aaStarData));
        }
        if (!registry.hasRole(registry.ROLE_PAYMASTER_SUPER(), jason)) {
            registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), jason, "");
        }
        sp.configureOperator(aPNTsAddr, jason, 1e18);

        // --- 3. 初始化 DemoCommunity (Anni) ---
        // 这里切换到 Anni 进行广播
        vm.stopBroadcast();
        vm.startBroadcast(anniPK);
        console.log("Registering DemoCommunity (Anni)...");
        Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
            name: "DemoCommunity",
            ensName: "demo.eth",
            website: "demo.com",
            description: "Demo Community for testing purposes.",
            logoURI: "ipfs://demo-logo",
            stakeAmount: 30 ether
        });

        gToken.approve(staking, 50 ether);
        if (!registry.hasRole(registry.ROLE_COMMUNITY(), anni)) {
            registry.registerRole(registry.ROLE_COMMUNITY(), anni, abi.encode(demoData));
        }

        address dPNTs = factory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
        if (!registry.hasRole(registry.ROLE_PAYMASTER_SUPER(), anni)) {
            registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
        }
        sp.configureOperator(dPNTs, anni, 1e18);
        vm.stopBroadcast();

        console.log("--- Initialization Success ---");
        console.log("dPNTs Address:", dPNTs);
    }
}
