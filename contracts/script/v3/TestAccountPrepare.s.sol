// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title TestAccountPrepare
 * @notice Phase 2: Test Account and Demo Preparation (Steps 39-51)
 * @dev Made idempotent to allow re-runs.
 */
contract TestAccountPrepare is Script {
    Registry registry;
    GToken gtoken;
    xPNTsFactory xpntsFactory;
    SuperPaymaster superPaymaster;
    PaymasterFactory pmFactory;
    address entryPointAddr;
    address priceFeedAddr;
    address stakingAddr;

    uint256 deployerPK;
    address deployer;

    function setUp() public {
        deployerPK = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPK);

        string memory network = vm.envString("ENV");
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json = vm.readFile(configPath);

        registry = Registry(stdJson.readAddress(json, ".registry"));
        gtoken = GToken(stdJson.readAddress(json, ".gToken"));
        xpntsFactory = xPNTsFactory(stdJson.readAddress(json, ".xPNTsFactory"));
        superPaymaster = SuperPaymaster(payable(stdJson.readAddress(json, ".superPaymaster")));
        pmFactory = PaymasterFactory(stdJson.readAddress(json, ".paymasterFactory"));
        stakingAddr = stdJson.readAddress(json, ".staking");

        if (keccak256(bytes(network)) == keccak256(bytes("anvil"))) {
            // On Anvil, everything is deployed locally, so we read from Config
            entryPointAddr = stdJson.readAddress(json, ".entryPoint");
            priceFeedAddr = stdJson.readAddress(json, ".priceFeed");
        } else {
            // On Testnet/Mainnet, Third-Party addresses MUST come from ENV
            entryPointAddr = vm.envAddress("ENTRYPOINT_ADDRESS");
            priceFeedAddr = vm.envAddress("PRICE_FEED_ADDRESS");
        }
    }

    function run() external {
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
        uint256 anniPK = vm.envOr("PRIVATE_KEY_ANNI", uint256(0));
        
        if (anniPK == 0) {
            console.log("PRIVATE_KEY_ANNI not set, skipping Anni setup.");
            return;
        }

        // --- Phase 2.1: Jason Prepares Anni ---
        vm.startBroadcast(deployerPK);
        
        bytes32 roleCommunity = registry.ROLE_COMMUNITY();
        string memory communityName = "AnniDemoCommunity"; 
        
        if (!registry.hasRole(roleCommunity, anni)) {
            console.log("Registering Community for Anni:", communityName);
            Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
                name: communityName,
                ensName: string.concat(communityName, ".eth"),
                website: "anni.demo",
                description: "Anni's Secret Demo Community",
                logoURI: "ipfs://anni-logo",
                stakeAmount: 30 ether
            });
            gtoken.mint(deployer, 40 ether); 
            gtoken.approve(stakingAddr, 40 ether);
            registry.safeMintForRole(roleCommunity, anni, abi.encode(demoData));
        }
        
        // Increase Anni's wallet to 200 GT to cover all future stakes
        if (gtoken.balanceOf(anni) < 150 ether) {
            console.log("Funding Anni with more GT tokens...");
            gtoken.transfer(anni, 200 ether);
        }
        if (address(anni).balance < 0.3 ether) {
             payable(anni).transfer(0.3 ether); 
        }
        vm.stopBroadcast();

        // --- Phase 2.2: Anni's Self-Setup ---
        vm.startBroadcast(anniPK);
        gtoken.approve(stakingAddr, 200 ether);
        
        if (!registry.hasRole(registry.ROLE_PAYMASTER_SUPER(), anni)) {
            console.log("Registering Anni as SuperPaymaster Operator...");
            gtoken.approve(stakingAddr, 200 ether);
            registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
        }

        address dPNTs = xpntsFactory.getTokenAddress(anni);
        if (dPNTs == address(0)) {
            console.log("Deploying dPNTs for Anni...");
            dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", communityName, string.concat(communityName, ".eth"), 1e18, address(0));
        }
        
        superPaymaster.configureOperator(dPNTs, anni, 1e18);

        address pmProxyAnni = pmFactory.getPaymasterByOperator(anni);
        if (pmProxyAnni == address(0)) {
            console.log("Deploying Anni's AOA Paymaster...");
            bytes memory initAnni = abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256,uint256)",
                entryPointAddr, anni, anni, priceFeedAddr, 100, 1 ether, 86400
            );
            pmProxyAnni = pmFactory.deployPaymaster("v4.2", initAnni);
            Paymaster(payable(pmProxyAnni)).addStake{value: 0.1 ether}(86400);
            Paymaster(payable(pmProxyAnni)).updatePrice();
            Paymaster(payable(pmProxyAnni)).setTokenPrice(dPNTs, 100_000_000); 
        }

        if (!registry.hasRole(registry.ROLE_PAYMASTER_AOA(), anni)) {
            console.log("Registering Anni's PAYMASTER_AOA role...");
            Registry.PaymasterRoleData memory pmDataAnni = Registry.PaymasterRoleData({
                paymasterContract: pmProxyAnni,
                name: "Anni V4 PM",
                apiEndpoint: "https://rpc.demo.io/pm",
                stakeAmount: 30 ether
            });
            registry.registerRole(registry.ROLE_PAYMASTER_AOA(), anni, abi.encode(pmDataAnni));
        }
        vm.stopBroadcast();

        // --- Phase 2.3: Final Funding ---
        vm.startBroadcast(deployerPK);
        if (IEntryPoint(entryPointAddr).balanceOf(pmProxyAnni) < 0.05 ether) {
            IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxyAnni);
        }
        vm.stopBroadcast();

        console.log("\n--- Phase 2: Test Preparation Complete ---");
    }
}
