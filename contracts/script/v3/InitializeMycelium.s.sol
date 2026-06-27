// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title InitializeMycelium
 * @notice Mainnet-safe community initialization for the Mycelium official community.
 *         Designed for Foundry keystore signing (--account ANNI_ACCOUNT).
 *         The deployer must have already run InitializeAAStar.s.sol (which grants
 *         ROLE_COMMUNITY + ROLE_PAYMASTER_AOA to ANNI_ADDRESS via safeMintForRole).
 *
 * Prerequisite: deployer pre-funds ANNI_ADDRESS with enough GToken for staking.
 *   Run InitializeAAStar first (deployer), then run this script as Anni:
 *
 *   source .env.op-mainnet
 *   # Step A: deployer grants Mycelium roles and pre-mints GToken for Anni
 *   forge script contracts/script/v3/InitializeMyceliumPrep.s.sol \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --slow -vv
 *
 *   # Step B: Anni deploys her token + V4 proxy (this script)
 *   forge script contracts/script/v3/InitializeMycelium.s.sol:InitializeMycelium \
 *     --rpc-url $RPC_URL --account $ANNI_ACCOUNT --broadcast --slow -vv
 *
 * Writes pnts and pNTsPaymasterV4 to config.<ENV>.json.
 */
contract InitializeMycelium is Script {
    bytes32 constant ROLE_COMMUNITY      = keccak256("COMMUNITY");
    bytes32 constant ROLE_PAYMASTER_AOA  = keccak256("PAYMASTER_AOA");

    function run() external {
        string memory network  = vm.envOr("ENV", string("op-mainnet"));
        string memory cfgPath  = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json     = vm.readFile(cfgPath);

        address anniAddr       = vm.envAddress("ANNI_ADDRESS");
        address registryAddr   = vm.parseJsonAddress(json, ".registry");
        address xpntsFactoryAddr = vm.parseJsonAddress(json, ".xPNTsFactory");
        address stakingAddr    = vm.parseJsonAddress(json, ".staking");
        address entryPointAddr = vm.parseJsonAddress(json, ".entryPoint");
        address priceFeedAddr  = vm.parseJsonAddress(json, ".priceFeed");
        address pmFactoryAddr  = vm.parseJsonAddress(json, ".paymasterFactory");

        Registry registry      = Registry(registryAddr);
        xPNTsFactory xpFactory = xPNTsFactory(xpntsFactoryAddr);
        PaymasterFactory pmFactory = PaymasterFactory(pmFactoryAddr);

        require(registry.hasRole(ROLE_COMMUNITY, anniAddr),
            "InitializeMycelium: ANNI_ADDRESS missing ROLE_COMMUNITY - run InitializeMyceliumPrep first");
        require(registry.hasRole(ROLE_PAYMASTER_AOA, anniAddr),
            "InitializeMycelium: ANNI_ADDRESS missing ROLE_PAYMASTER_AOA - run InitializeMyceliumPrep first");

        vm.startBroadcast();

        // Step 1: Deploy PNTs token if missing
        address pntsAddr = xpFactory.getTokenAddress(anniAddr);
        if (pntsAddr == address(0)) {
            console.log("[InitializeMycelium] Deploying PNTs token...");
            pntsAddr = xpFactory.deployxPNTsToken(
                "Mycelium PNTs", "PNTs", "Mycelium Community", "mushroom.box", 1e18, address(0)
            );
            console.log("  PNTs deployed:", pntsAddr);
        } else {
            console.log("[InitializeMycelium] PNTs already deployed:", pntsAddr);
        }
        vm.writeJson(vm.toString(pntsAddr), cfgPath, ".pnts");

        // Step 2: Deploy pNTs PaymasterV4 proxy if missing
        address pmProxy = pmFactory.getPaymasterByOperator(anniAddr);
        if (pmProxy == address(0)) {
            console.log("[InitializeMycelium] Deploying Mycelium PaymasterV4 (AOA) proxy...");
            bytes memory initData = abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256,uint256)",
                entryPointAddr,
                anniAddr,
                anniAddr,
                priceFeedAddr,
                100,       // serviceFeeRate 1%
                1 ether,   // maxGasCostCap
                86400      // priceStalenessThreshold
            );
            pmProxy = pmFactory.deployPaymaster("v4.2", initData);
            console.log("  pNTs V4 proxy deployed:", pmProxy);
        } else {
            console.log("[InitializeMycelium] pNTs V4 proxy already deployed:", pmProxy);
        }

        // Step 3: Correct token price (idempotent, $0.02)
        uint256 curPrice = Paymaster(payable(pmProxy)).tokenPrices(pntsAddr);
        if (curPrice != 2_000_000) {
            Paymaster(payable(pmProxy)).setTokenPrice(pntsAddr, 2_000_000);
            console.log("[InitializeMycelium] pNTs price set to $0.02");
        }

        // Step 4: Top up EntryPoint deposit (gap only, idempotent target 0.1 ETH)
        uint256 epBal = IEntryPoint(entryPointAddr).balanceOf(pmProxy);
        if (epBal < 0.1 ether) {
            uint256 topUp = 0.1 ether - epBal;
            IEntryPoint(entryPointAddr).depositTo{value: topUp}(pmProxy);
            console.log("[InitializeMycelium] Deposited ETH to EntryPoint:", topUp);
        }

        vm.writeJson(vm.toString(pmProxy), cfgPath, ".pntsPaymasterV4");
        console.log("[InitializeMycelium] Done. pNTsPaymasterV4:", pmProxy);

        vm.stopBroadcast();
    }
}
