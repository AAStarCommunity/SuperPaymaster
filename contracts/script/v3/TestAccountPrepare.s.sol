// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
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

        // Resolve keys from env (fall back to Anvil constants for local dev).
        // GUARD: this script broadcasts with an explicit PK (vm.startBroadcast(pk))
        // and derives the deployer ADDRESS from it (vm.addr) for mint targets, so a
        // Foundry keystore (--account) alone is NOT enough. On any non-anvil network
        // we MUST have PRIVATE_KEY / PRIVATE_KEY_ANNI — otherwise we'd silently sign
        // with the hardcoded Anvil keys and mint to the wrong (anvil) address.
        bool isAnvil = keccak256(bytes(network)) == keccak256(bytes("anvil"));
        if (!isAnvil) {
            require(vm.envOr("PRIVATE_KEY", uint256(0)) != 0,
                "TestAccountPrepare: set PRIVATE_KEY for non-anvil (keystore-only not supported by this script)");
            require(vm.envOr("PRIVATE_KEY_ANNI", uint256(0)) != 0,
                "TestAccountPrepare: set PRIVATE_KEY_ANNI for non-anvil");
        }
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
        xPNTsToken apnts             = xPNTsToken(stdJson.readAddress(json, ".aPNTs"));

        // -----------------------------------------------------------------------
        // Phase 2.0: Deployer registers Anni as COMMUNITY + PAYMASTER_SUPER
        //   (idempotent — skipped if already granted)
        //   Required before TestAccountPrepare can register PAYMASTER_AOA.
        //   Mirrors _setupMyceliumCommunity() in DeployLive.s.sol.
        // -----------------------------------------------------------------------
        vm.startBroadcast(deployerPK);
        if (!registry.hasRole(ROLE_COMMUNITY, anniAddr)) {
            console.log("[Phase 2.0] Registering Anni as COMMUNITY (Mycelium)...");
            // Ensure deployer has GToken for stake + burn
            gtoken.mint(vm.addr(deployerPK), 100 ether);
            gtoken.approve(stakingAddr, 100 ether);
            Registry.CommunityRoleData memory mycData = Registry.CommunityRoleData({
                name: "Mycelium Community",
                ensName: "mushroom.box",
                stakeAmount: 30 ether
            });
            registry.safeMintForRole(ROLE_COMMUNITY, anniAddr, abi.encode(mycData));
            console.log("  Mycelium Community registered for Anni");
        }
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, anniAddr)) {
            console.log("[Phase 2.0] Registering Anni as PAYMASTER_SUPER...");
            gtoken.approve(stakingAddr, 60 ether);
            registry.safeMintForRole(ROLE_PAYMASTER_SUPER, anniAddr, "");
            console.log("  PAYMASTER_SUPER granted to Anni");
        }
        // Ensure deployer has aPNTs to transfer (mint if needed — deployer is communityOwner)
        if (apnts.balanceOf(vm.addr(deployerPK)) < 1000 ether) {
            console.log("[Phase 2.0] Minting 20000 aPNTs to deployer...");
            apnts.mint(vm.addr(deployerPK), 20_000 ether);
        }
        // Transfer aPNTs to Anni if she has less than 1000 (for SP deposit)
        if (apnts.balanceOf(anniAddr) < 1000 ether) {
            console.log("[Phase 2.0] Transferring 1000 aPNTs to Anni...");
            apnts.transfer(anniAddr, 1000 ether);
        }
        vm.stopBroadcast();

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

        // Deploy Anni's PNTs xPNTs token + configure SP operator (mirrors DeployLive step 6d-6f)
        address pntsAddr = xpntsFactory.getTokenAddress(anniAddr);
        if (pntsAddr == address(0)) {
            console.log("[Phase 2.2] Deploying Anni's PNTs token...");
            pntsAddr = xpntsFactory.deployxPNTsToken(
                "Mycelium PNTs", "PNTs", "Mycelium Community", "mushroom.box", 1e18, address(0)
            );
            console.log("  PNTs deployed:", pntsAddr);
        }
        (uint128 anniBal, bool isCfgAnni,,,,,,,) = superPaymaster.operators(anniAddr);
        if (!isCfgAnni) {
            console.log("[Phase 2.2] Configuring Anni as SuperPaymaster operator...");
            superPaymaster.configureOperator(pntsAddr, anniAddr);
            console.log("  Operator configured");
        }
        // Deposit 1000 aPNTs into SuperPaymaster if balance is low
        if (anniBal < 100 ether) {
            console.log("[Phase 2.2] Depositing aPNTs to SuperPaymaster for Anni...");
            apnts.approve(address(superPaymaster), 1000 ether);
            superPaymaster.deposit(1000 ether);
            console.log("  1000 aPNTs deposited");
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
