// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/GToken.sol";
import {V55Bootstrap} from "./V55Bootstrap.sol";

/**
 * @title InitializeTestCommunities
 * @notice Register the AAStar (Jason) and DemoCommunity (Anni) test communities on an EXISTING
 *         SuperPaymaster 5.5.0 deployment and make both live SP operators.
 * @dev    D5.2 migration. The previous version could not compile against this tree:
 *         `CommunityRoleData` lost website/description/logoURI, and `configureOperator` lost its
 *         third (exchange-rate) argument — the rate is now read from the token at runtime. It also
 *         configured the 3.x aPNTs / a 3.x dPNTs as operator tokens, which SP 5.5.0 rejects
 *         (InvalidXPNTsToken): operator tokens must be xPNTs v2 tokens from the factory SP is
 *         wired to (`config.xPNTsFactoryV2`). Idempotent; every step is read back.
 *
 * Run (anvil):
 *   NETWORK=anvil PRIVATE_KEY=0xac09… forge script \
 *     contracts/script/v3/InitializeTestCommunities.s.sol:InitializeTestCommunities \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract InitializeTestCommunities is V55Bootstrap {
    function run() external {
        string memory root = vm.projectRoot();
        string memory network = vm.envOr("NETWORK", string("anvil"));
        string memory configPath = string.concat(root, "/deployments/config.", network, ".json");
        string memory json = vm.readFile(configPath);

        Registry registry = Registry(vm.parseJsonAddress(json, ".registry"));
        SuperPaymaster sp = SuperPaymaster(payable(vm.parseJsonAddress(json, ".superPaymaster")));
        address factoryV2 = vm.parseJsonAddress(json, ".xPNTsFactoryV2");
        address aPNTsAddr = vm.parseJsonAddress(json, ".aPNTs");
        GToken gToken = GToken(vm.parseJsonAddress(json, ".gToken"));
        require(_strEq(sp.version(), SP_V55_VERSION), "InitializeTestCommunities: SP is not 5.5.0");
        require(sp.xpntsFactory() == factoryV2, "InitializeTestCommunities: SP.xpntsFactory != config.xPNTsFactoryV2");

        uint256 jasonPK = vm.envUint("PRIVATE_KEY");
        uint256 anniPK = vm.envOr(
            "PRIVATE_KEY_ANNI", uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)
        );
        address jason = vm.addr(jasonPK);
        address anni = vm.addr(anniPK);
        address staking = address(registry.GTOKEN_STAKING());

        // --- 1. Fund Jason and Anni with GToken (anvil: deployer owns GToken) ---
        vm.startBroadcast(jasonPK);
        try gToken.mint(jason, 1000 ether) {} catch {}
        try gToken.mint(anni, 1000 ether) {} catch {}

        // --- 2. AAStar (Jason) ---
        console.log("Registering AAStar community...");
        gToken.approve(staking, 200 ether);
        if (!registry.hasRole(ROLE_COMMUNITY, jason)) {
            Registry.CommunityRoleData memory aaStarData =
                Registry.CommunityRoleData({name: "AAStar", ensName: "aastar.eth", stakeAmount: 30 ether});
            registry.registerRole(ROLE_COMMUNITY, jason, abi.encode(aaStarData));
        }
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, jason)) {
            registry.registerRole(ROLE_PAYMASTER_SUPER, jason, "");
        }
        address aXPNTs = _issueV2Token(factoryV2, jason, "AAStar xPNTs", "aXPNTs", "AAStar", "aastar.eth", 1e18);
        _configureOperatorV2(address(sp), aXPNTs, jason, jason);
        vm.stopBroadcast();

        // --- 3. DemoCommunity (Anni) ---
        vm.startBroadcast(anniPK);
        console.log("Registering DemoCommunity (Anni)...");
        gToken.approve(staking, 200 ether);
        if (!registry.hasRole(ROLE_COMMUNITY, anni)) {
            Registry.CommunityRoleData memory demoData =
                Registry.CommunityRoleData({name: "DemoCommunity", ensName: "demo.eth", stakeAmount: 30 ether});
            registry.registerRole(ROLE_COMMUNITY, anni, abi.encode(demoData));
        }
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, anni)) {
            registry.registerRole(ROLE_PAYMASTER_SUPER, anni, "");
        }
        address dPNTs = _issueV2Token(factoryV2, anni, "DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18);
        _configureOperatorV2(address(sp), dPNTs, anni, anni);
        vm.stopBroadcast();

        // --- 4. Read back ---
        _verifyV2Token(aXPNTs, factoryV2, jason, address(sp));
        _verifyV2Token(dPNTs, factoryV2, anni, address(sp));
        _verifyOperatorV2(address(sp), jason, aXPNTs, jason);
        _verifyOperatorV2(address(sp), anni, dPNTs, anni);
        console.log("--- Initialization Success ---");
        console.log("aXPNTs (v2):", aXPNTs);
        console.log("dPNTs  (v2):", dPNTs);
        console.log("aPNTs (deposit asset, unchanged):", aPNTsAddr);
    }
}
