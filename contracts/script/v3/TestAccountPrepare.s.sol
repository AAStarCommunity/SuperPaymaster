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
 */
contract TestAccountPrepare is Script {
    Registry registry;
    GToken gtoken;
    xPNTsToken apntsMock; // Used for interface calls
    xPNTsFactory xpntsFactory;
    SuperPaymaster superPaymaster;
    PaymasterFactory pmFactory;
    address entryPointAddr;
    address priceFeedAddr;

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
        entryPointAddr = stdJson.readAddress(json, ".entryPoint");
        priceFeedAddr = stdJson.readAddress(json, ".priceFeed");
    }

    function run() external {
        // Step 39-41: Jason (Deployer) Prepares Anni
        vm.startBroadcast(deployerPK);
        
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
        uint256 anniPK = vm.envOr("PRIVATE_KEY_ANNI", uint256(0));
        
        if (anniPK == 0) {
            console.log("PRIVATE_KEY_ANNI not set, skipping Anni setup.");
            vm.stopBroadcast();
            return;
        }

        // Step 40: Register DemoCommunity
        Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
            name: "DemoCommunity",
            ensName: "demo.eth",
            website: "demo.com",
            description: "Anni's Demo Community",
            logoURI: "ipfs://demo-logo",
            stakeAmount: 30 ether
        });
        gtoken.mint(deployer, 33 ether);
        gtoken.approve(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", vm.envString("ENV"), ".json")), ".staking"), 33 ether);
        registry.safeMintForRole(registry.ROLE_COMMUNITY(), anni, abi.encode(demoData));
        
        // Step 41: Transfer GT and ETH to Anni
        gtoken.transfer(anni, 100 ether);
        payable(anni).transfer(1 ether); // Fund Anni with ETH for gas/staking
        vm.stopBroadcast();

        // Step 42-50: Switch to Anni
        vm.startBroadcast(anniPK);
        gtoken.approve(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", vm.envString("ENV"), ".json")), ".staking"), 100 ether);
        
        // Step 43: Register as SP Operator
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
        
        // Step 44-45: Deploy dPNTs & Configure SP
        address dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
        superPaymaster.configureOperator(dPNTs, anni, 1e18);

        // Step 46-49: Anni's AOA Paymaster
        bytes memory initAnni = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            entryPointAddr, anni, anni, priceFeedAddr, 100, 1 ether, 86400
        );
        address pmProxyAnni = pmFactory.deployPaymaster("v4.2", initAnni);
        Paymaster(payable(pmProxyAnni)).addStake{value: 0.1 ether}(86400);
        Paymaster(payable(pmProxyAnni)).updatePrice();
        Paymaster(payable(pmProxyAnni)).setTokenPrice(dPNTs, 100_000_000); // $1.00 for demo points

        // Step 50: Register PM_AOA role for Anni
        Registry.PaymasterRoleData memory pmDataAnni = Registry.PaymasterRoleData({
            paymasterContract: pmProxyAnni,
            name: "Anni V4 PM",
            apiEndpoint: "https://rpc.demo.io/pm",
            stakeAmount: 30 ether
        });
        registry.registerRole(keccak256("PAYMASTER_AOA"), anni, abi.encode(pmDataAnni));
        vm.stopBroadcast();

        // Step 51: Switch back to Jason to fund Anni's PM Gas
        vm.startBroadcast(deployerPK);
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxyAnni);
        vm.stopBroadcast();

        console.log("\n--- Phase 2: Test Preparation Complete ---");
    }
}
