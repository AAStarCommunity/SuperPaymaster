// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";

/**
 * @title DeployCC28Factory
 * @notice CC-28 (over-issue model) deployment — Option B (non-disruptive).
 *
 * The xPNTsFactory is NOT upgradeable (it clones a fixed token impl set in its constructor),
 * so shipping CC-28's isOverIssued()/governance-baseline surface requires a NEW factory. The
 * existing official communities (AAStar/Mycelium) stay on the OLD factory (untouched); a fresh
 * CC-28 test community is created here so DVT can exercise audit rule ③ end-to-end. SP's factory
 * pointer is deliberately NOT swapped (that cutover + official-community migration is a follow-up).
 *
 * Steps:
 *   1. deployer  → deploy new CC-28 xPNTsFactory(SP, Registry) [owner = deployer/governance]
 *   2. Anni      → deployxPNTsToken(...) on the new factory (she holds registry ROLE_COMMUNITY;
 *                  no token yet on this factory) + mint over the $10k default baseline
 *   3. assert    → isOverIssued() == true on the demo token (baseline breach, no backing)
 *   4. record    → write new factory + demo token to config.sepolia.json
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/DeployCC28Factory.s.sol:DeployCC28Factory \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast -vvvv
 */
contract DeployCC28Factory is Script {
    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address sp = vm.parseJsonAddress(config, ".superPaymaster");
        address registry = vm.parseJsonAddress(config, ".registry");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 anniPk = vm.envUint("PRIVATE_KEY_ANNI");
        address anni = vm.addr(anniPk);

        console.log("=== CC-28 factory deploy (Option B, non-disruptive) ===");
        console.log("  SP:", sp);
        console.log("  Registry:", registry);
        console.log("  Community (Anni):", anni);

        // 1. Deploy the new CC-28 factory (owner = deployer = governance).
        vm.startBroadcast(deployerPk);
        xPNTsFactory factory = new xPNTsFactory(sp, registry);
        vm.stopBroadcast();

        require(factory.SUPERPAYMASTER() == sp, "CC28: SP not wired");
        require(factory.capRatioBps() == 10_000, "CC28: capRatioBps seed");
        require(factory.industryScaleUSD("DeFi") == 50_000 ether, "CC28: DeFi baseline seed");
        require(factory.categoryRegistered("default"), "CC28: default not registered");
        console.log("  New CC-28 factory:", address(factory));

        // 2. Anni creates a CC-28 test community on the new factory + mints over the default
        //    $10,000 baseline (600,000 xPNTs * $0.02 = $12,000) to demonstrate over-issue.
        vm.startBroadcast(anniPk);
        address testToken = factory.deployxPNTsToken(
            "CC28 Test PNTs", "cc28PNT", "CC28Test", "cc28.test.eth", 1e18, address(0)
        );
        xPNTsToken(testToken).mint(anni, 600_000 ether);
        vm.stopBroadcast();

        // 3. Verify the demo token reports over-issued (baseline breach, no backing).
        xPNTsToken t = xPNTsToken(testToken);
        require(t.issuedValueUSD() == 12_000 ether, "CC28: issued value");
        require(t.effectiveCapUSD() == 10_000 ether, "CC28: default cap");
        require(t.isOverIssued(), "CC28: demo token should be over-issued");
        console.log("  CC-28 demo token:", testToken);
        console.log("  issuedValueUSD:", t.issuedValueUSD());
        console.log("  effectiveCapUSD:", t.effectiveCapUSD());
        console.log("  isOverIssued:", t.isOverIssued());

        // 4. Record (additive keys — old factory / official communities untouched).
        vm.writeJson(vm.toString(address(factory)), configPath, ".xPNTsFactoryCC28");
        vm.writeJson(vm.toString(testToken), configPath, ".xPNTsTokenCC28Test");
        // Read both keys back so a silent vm.writeJson no-op fails loud (mirrors #342 L-2).
        string memory written = vm.readFile(configPath);
        require(
            vm.parseJsonAddress(written, ".xPNTsFactoryCC28") == address(factory),
            "CC28: factory config write failed"
        );
        require(
            vm.parseJsonAddress(written, ".xPNTsTokenCC28Test") == testToken,
            "CC28: token config write failed"
        );
        console.log("=== Done. CC-28 factory live; official communities unaffected. ===");
    }
}
