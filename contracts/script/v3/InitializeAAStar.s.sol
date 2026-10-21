// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SPReleaseVersion } from "./SPReleaseVersion.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

// ROLE_COMMUNITY, ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER are file-level
// constants from IRegistry.sol (imported above) — no local redeclaration needed.

/**
 * @title InitializeAAStar
 * @notice Mainnet-safe community initialization for the AAStar official community.
 *         Designed for Foundry keystore signing (--account DEPLOYER_ACCOUNT).
 *         Does NOT use PRIVATE_KEY env var. Idempotent: each step is guarded.
 *
 * Run:
 *   source .env.op-mainnet
 *   forge script contracts/script/v3/InitializeAAStar.s.sol:InitializeAAStar \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --slow -vv
 *
 * Writes aPNTs and aPNTsPaymasterV4 to config.<ENV>.json (and, on SuperPaymaster 5.5.0,
 * aastarXPNTsV2 — the v2 operator token SP requires; the 3.x aPNTs stays the deposit asset).
 */
contract InitializeAAStar is Script {
    function run() external {
        string memory network  = vm.envOr("ENV", string("op-mainnet"));
        string memory cfgPath  = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json     = vm.readFile(cfgPath);

        address deployerAddr     = vm.envAddress("DEPLOYER_ADDRESS");
        address registryAddr     = vm.parseJsonAddress(json, ".registry");
        address spAddr           = vm.parseJsonAddress(json, ".superPaymaster");
        address xpntsFactoryAddr = vm.parseJsonAddress(json, ".xPNTsFactory");
        address stakingAddr      = vm.parseJsonAddress(json, ".staking");
        address gTokenAddr       = vm.parseJsonAddress(json, ".gToken");
        address entryPointAddr   = vm.parseJsonAddress(json, ".entryPoint");
        address priceFeedAddr    = vm.parseJsonAddress(json, ".priceFeed");
        address pmFactoryAddr    = vm.parseJsonAddress(json, ".paymasterFactory");

        Registry registry        = Registry(registryAddr);
        SuperPaymaster sp        = SuperPaymaster(payable(spAddr));
        xPNTsFactory xpFactory   = xPNTsFactory(xpntsFactoryAddr);
        GToken gtoken            = GToken(gTokenAddr);
        PaymasterFactory pmFactory = PaymasterFactory(pmFactoryAddr);

        vm.startBroadcast();

        // Step 1: Register AAStar as COMMUNITY if not already
        if (!registry.hasRole(ROLE_COMMUNITY, deployerAddr)) {
            console.log("[InitializeAAStar] Registering AAStar as COMMUNITY...");
            gtoken.approve(stakingAddr, 50 ether);
            Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
                name: "AAStar",
                ensName: "aastar.eth",
                stakeAmount: 30 ether
            });
            registry.safeMintForRole(ROLE_COMMUNITY, deployerAddr, abi.encode(aaStarData));
            console.log("  AAStar COMMUNITY registered");
        } else {
            console.log("[InitializeAAStar] AAStar COMMUNITY already registered, skip");
        }

        // Step 2: Grant PAYMASTER_SUPER if missing (for SuperPaymaster operator)
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, deployerAddr)) {
            console.log("[InitializeAAStar] Granting PAYMASTER_SUPER...");
            gtoken.approve(stakingAddr, 60 ether);
            registry.safeMintForRole(ROLE_PAYMASTER_SUPER, deployerAddr, "");
        }

        // Step 3: Deploy aPNTs token if missing
        address apntsAddr = xpFactory.getTokenAddress(deployerAddr);
        if (apntsAddr == address(0)) {
            console.log("[InitializeAAStar] Deploying aPNTs token...");
            apntsAddr = xpFactory.deployxPNTsToken(
                "AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0)
            );
            console.log("  aPNTs deployed:", apntsAddr);
        } else {
            console.log("[InitializeAAStar] aPNTs already deployed:", apntsAddr);
        }
        vm.writeJson(vm.toString(apntsAddr), cfgPath, ".aPNTs");

        // Step 4: Configure deployer as SuperPaymaster operator if not done.
        // 5.5.0: SP only accepts an xPNTs v2 token from the factory it is wired to
        // (xPNTsFactoryV2); the 3.x aPNTs above stays the operator DEPOSIT asset.
        address opToken = apntsAddr;
        if (keccak256(bytes(sp.version())) == keccak256(bytes(SPReleaseVersion.SP))) {
            address factoryV2 = sp.xpntsFactory();
            require(factoryV2 == vm.parseJsonAddress(json, ".xPNTsFactoryV2"), "InitializeAAStar: SP factory != config.xPNTsFactoryV2");
            // xPNTsFactoryV2 keeps the 3.x getTokenAddress / deployxPNTsToken signatures.
            opToken = xPNTsFactory(factoryV2).getTokenAddress(deployerAddr);
            if (opToken == address(0)) {
                console.log("[InitializeAAStar] Issuing AAStar xPNTs v2 operator token...");
                opToken = xPNTsFactory(factoryV2).deployxPNTsToken(
                    "AAStar xPNTs", "aXPNTs", "AAStar", "aastar.eth", 1e18, address(0)
                );
            }
            vm.writeJson(vm.toString(opToken), cfgPath, ".aastarXPNTsV2");
        }
        (, bool isCfg,, address curTok,,,,,) = sp.operators(deployerAddr);
        if (!isCfg || curTok != opToken) {
            console.log("[InitializeAAStar] Configuring SuperPaymaster operator...");
            sp.configureOperator(opToken, deployerAddr);
        }
        (, bool cfgAfter,, address tokAfter,,,,,) = sp.operators(deployerAddr);
        require(cfgAfter && tokAfter == opToken, "InitializeAAStar: operator read-back failed");

        // Step 5: Grant PAYMASTER_AOA for V4 deployment
        if (!registry.hasRole(ROLE_PAYMASTER_AOA, deployerAddr)) {
            console.log("[InitializeAAStar] Granting PAYMASTER_AOA...");
            gtoken.approve(stakingAddr, 50 ether);
            registry.registerRole(ROLE_PAYMASTER_AOA, deployerAddr, "");
        }

        // Step 6: Deploy aPNTs PaymasterV4 proxy if missing
        address pmProxy = pmFactory.getPaymasterByOperator(deployerAddr);
        if (pmProxy == address(0)) {
            console.log("[InitializeAAStar] Deploying AAStar PaymasterV4 (AOA) proxy...");
            bytes memory initData = abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256,uint256)",
                entryPointAddr,
                deployerAddr,
                deployerAddr,
                priceFeedAddr,
                100,       // serviceFeeRate 1%
                1 ether,   // maxGasCostCap
                86400      // priceStalenessThreshold
            );
            pmProxy = pmFactory.deployPaymaster("v4.2", initData);
            console.log("  aPNTs V4 proxy deployed:", pmProxy);
        } else {
            console.log("[InitializeAAStar] aPNTs V4 proxy already deployed:", pmProxy);
        }

        // Step 7: Correct token price (idempotent — $0.02 = 2_000_000 with 8 decimals)
        uint256 curPrice = Paymaster(payable(pmProxy)).tokenPrices(apntsAddr);
        if (curPrice != 2_000_000) {
            Paymaster(payable(pmProxy)).setTokenPrice(apntsAddr, 2_000_000);
            console.log("[InitializeAAStar] aPNTs price set to $0.02 (2000000)");
        }

        // Step 8: Top up EntryPoint deposit (gap only, idempotent target 0.1 ETH)
        uint256 epBal = IEntryPoint(entryPointAddr).balanceOf(pmProxy);
        if (epBal < 0.1 ether) {
            uint256 topUp = 0.1 ether - epBal;
            IEntryPoint(entryPointAddr).depositTo{value: topUp}(pmProxy);
            console.log("[InitializeAAStar] Deposited ETH to EntryPoint:", topUp);
        }

        vm.writeJson(vm.toString(pmProxy), cfgPath, ".aPNTsPaymasterV4");
        console.log("[InitializeAAStar] Done. aPNTsPaymasterV4:", pmProxy);

        vm.stopBroadcast();
    }
}
