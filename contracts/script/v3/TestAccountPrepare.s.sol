// SPDX-License-Identifier: Apache-2.0
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
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestAccountPrepare
 * @notice Phase 2: Test Account and Demo Preparation for local Anvil regression.
 * @dev Sets up the "Anni" demo operator (Anvil account #1) with:
 *      - ROLE_PAYMASTER_AOA (required by Check09_TestAccounts)
 *      - A deployed V4 (AOA) Paymaster proxy via PaymasterFactory
 *      - Sufficient EntryPoint deposit for the V4 paymaster
 *      Idempotent: each step is guarded by an existence/balance check.
 */
contract TestAccountPrepare is Script {
    // Anvil fallback keys (used when env vars are not set)
    uint256 constant ANVIL_ANNI_PK     = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant ANVIL_DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        string memory network   = vm.envOr("ENV", string("anvil"));
        string memory cfgPath   = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json      = vm.readFile(cfgPath);

        // Resolve keys from env (fall back to Anvil constants for local dev)
        uint256 deployerPK = vm.envOr("PRIVATE_KEY", ANVIL_DEPLOYER_PK);
        uint256 anniPK     = vm.envOr("PRIVATE_KEY_ANNI", ANVIL_ANNI_PK);
        address anniAddr   = vm.addr(anniPK);

        // Load deployed contract addresses
        Registry       registry      = Registry(stdJson.readAddress(json, ".registry"));
        GToken         gtoken        = GToken(stdJson.readAddress(json, ".gToken"));
        xPNTsFactory   xpntsFactory  = xPNTsFactory(stdJson.readAddress(json, ".xPNTsFactory"));
        SuperPaymaster superPaymaster = SuperPaymaster(payable(stdJson.readAddress(json, ".superPaymaster")));
        PaymasterFactory pmFactory   = PaymasterFactory(stdJson.readAddress(json, ".paymasterFactory"));
        address entryPointAddr       = stdJson.readAddress(json, ".entryPoint");
        address priceFeedAddr        = stdJson.readAddress(json, ".priceFeed");
        address stakingAddr          = stdJson.readAddress(json, ".staking");

        // -----------------------------------------------------------------------
        // Phase 2.1: Deployer top-ups Anni's GT balance so she can stake
        // -----------------------------------------------------------------------
        vm.startBroadcast(deployerPK);
        if (gtoken.balanceOf(anniAddr) < 150 ether) {
            console.log("[Phase 2.1] Minting GT for Anni...");
            gtoken.mint(anniAddr, 200 ether);
        }
        vm.stopBroadcast();

        // -----------------------------------------------------------------------
        // Phase 2.2: Anni registers PAYMASTER_AOA and deploys her V4 proxy
        // -----------------------------------------------------------------------
        vm.startBroadcast(anniPK);

        // Register ROLE_PAYMASTER_AOA if Anni doesn't have it yet
        if (!registry.hasRole(ROLE_PAYMASTER_AOA, anniAddr)) {
            console.log("[Phase 2.2] Registering Anni as PAYMASTER_AOA...");
            gtoken.approve(stakingAddr, 50 ether);
            registry.registerRole(ROLE_PAYMASTER_AOA, anniAddr, "");
        }

        // Deploy Anni's V4 paymaster proxy if not yet deployed
        address pmProxyAnni = pmFactory.getPaymasterByOperator(anniAddr);
        if (pmProxyAnni == address(0)) {
            console.log("[Phase 2.2] Deploying Anni's AOA Paymaster (V4)...");
            address dPNTs = xpntsFactory.getTokenAddress(anniAddr);
            bytes memory initData = abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256,uint256)",
                entryPointAddr,
                anniAddr,   // owner
                anniAddr,   // treasury
                priceFeedAddr,
                100,        // serviceFeeRate (1%)
                1 ether,    // maxGasCostCap
                86400       // priceStalenessThreshold (1 day)
            );
            pmProxyAnni = pmFactory.deployPaymaster("v4.2", initData);
            console.log("  Anni PM proxy:", pmProxyAnni);

            // Configure token price so the paymaster can quote gas costs
            if (dPNTs != address(0)) {
                Paymaster(payable(pmProxyAnni)).setTokenPrice(dPNTs, 100_000_000); // $1.00 per token
            }
        }
        vm.stopBroadcast();

        // -----------------------------------------------------------------------
        // Phase 2.3: Deployer deposits ETH into EntryPoint for Anni's paymaster
        // -----------------------------------------------------------------------
        vm.startBroadcast(deployerPK);
        if (IEntryPoint(entryPointAddr).balanceOf(pmProxyAnni) < 0.05 ether) {
            console.log("[Phase 2.3] Depositing 0.05 ETH to EntryPoint for Anni PM...");
            IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxyAnni);
        }
        vm.stopBroadcast();

        // -----------------------------------------------------------------------
        // Phase 2.4: Refresh paymaster price caches
        //
        // Both PaymasterV4 and SuperPaymaster cache the Chainlink ETH/USD price
        // and use it to compute gas cost in aPNTs. If the cache is stale
        // (block.timestamp > cachedPrice.updatedAt + priceStalenessThreshold)
        // validatePaymasterUserOp returns validUntil in the past and the
        // EntryPoint rejects the userOp with "AA32 paymaster expired or not
        // due". prepare-test runs at deploy time so it should leave both
        // paymasters with fresh caches. See docs/gasless-test-troubleshooting.md
        // section 1.3.
        // -----------------------------------------------------------------------
        vm.startBroadcast(deployerPK);
        console.log("[Phase 2.4] Refreshing paymaster price caches...");
        // SuperPaymaster.updatePrice() — non-fatal on failure (e.g. price-oracle
        // unavailable on local anvil with mock feed).
        (bool spOk,) = address(superPaymaster).call(abi.encodeWithSignature("updatePrice()"));
        if (spOk) {
            console.log("  SuperPaymaster.updatePrice() OK");
        } else {
            console.log("  SuperPaymaster.updatePrice() skipped (oracle unavailable)");
        }
        // PaymasterV4 (Anni's proxy) — same pattern.
        if (pmProxyAnni != address(0)) {
            (bool v4Ok,) = pmProxyAnni.call(abi.encodeWithSignature("updatePrice()"));
            if (v4Ok) {
                console.log("  Anni V4 paymaster updatePrice() OK");
            } else {
                console.log("  Anni V4 paymaster updatePrice() skipped");
            }
        }
        vm.stopBroadcast();

        // -----------------------------------------------------------------------
        // Phase 2.5: Print Operator → xPNTsToken matrix (diagnostic, no writes)
        //
        // Critical invariant: SP gasless tests must transfer the same token
        // their operator is configured with (operator.xPNTsToken). Mismatch
        // causes outer status=1 / inner transfer reverted in postOp. See
        // docs/gasless-test-troubleshooting.md section 1.6.
        // -----------------------------------------------------------------------
        console.log("\n[Phase 2.5] Operator -> xPNTsToken Matrix:");
        address deployerAddr = vm.addr(deployerPK);
        _printOperatorRow("  deployer", deployerAddr, superPaymaster);
        _printOperatorRow("  Anni    ", anniAddr,     superPaymaster);

        console.log("\n--- Phase 2: Test Preparation Complete ---");
        console.log("  Anni address:   ", anniAddr);
        console.log("  Anni PM proxy:  ", pmProxyAnni);
    }

    /// @dev Read-only helper: log a single row of the operator matrix.
    function _printOperatorRow(string memory label, address op, SuperPaymaster sp) internal view {
        (uint128 bal, bool isCfg, , address xpnts, , , , , ) = sp.operators(op);
        console.log(label, op);
        console.log("    isConfigured:", isCfg);
        console.log("    xPNTsToken: ", xpnts);
        console.log("    aPNTsBalance:", uint256(bal));
    }
}
