// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import {GTokenAuthorization} from "src/tokens/GTokenAuthorization.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {V55Bootstrap} from "./V55Bootstrap.sol";

/// @dev Local-only price feed (same shape as DeployAnvil's MockPriceFeed).
contract BLayerPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/**
 * @title DeployBLayerAnvil
 * @notice D5 gate G1 (B1–B10, docs/design/aoa-balance-mode/D5-plan.md §3): the SuperPaymaster 5.5.0
 *         validation path on a FRESH local anvil, against the CANONICAL EntryPoint v0.7 that the
 *         harness has already etched at 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (off-the-shelf
 *         bundlers only recognise that address).
 * @dev    Deliberately the subset of DeployAnvil that the validation path touches: Registry +
 *         GTokenStaking + MySBT (roles), the 3.x factory + aPNTs (APNTS_TOKEN, operator deposit
 *         asset), SP 5.5.0 (profile.default artifact via V55Bootstrap._deployDefault, AUD-4),
 *         the xPNTs v2 stack, one v2 operator token, configureOperator. No BLS/DVT/x402 modules,
 *         so no governance-owned component exists here and DeployAnvil's governance gate has
 *         nothing to guard. The script refuses anything but a fresh local chain (a fork also
 *         reports 31337, so the block height is checked too). Writes the addresses to
 *         $BLAYER_CONFIG_OUT (path relative to the project root); never touches tracked configs.
 */
contract DeployBLayerAnvil is V55Bootstrap {
    address internal constant EP_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    // anvil dev key #0 (public, local-only)
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        require(block.chainid == 31337, "B-layer: local anvil (31337) only");
        require(block.number < 1000, "B-layer: fresh local chain only (a fork of a live chain is refused)");
        require(EP_V07.code.length > 0, "B-layer: etch the canonical EntryPoint v0.7 first");
        address deployer = vm.addr(DEPLOYER_PK);

        vm.startBroadcast(DEPLOYER_PK);
        address priceFeed = address(new BLayerPriceFeed());

        Registry regImpl = new Registry();
        Registry registry = Registry(address(new ERC1967Proxy(
            address(regImpl), abi.encodeCall(Registry.initialize, (deployer, address(0), address(0)))
        )));
        xPNTsFactory factoryV1 = new xPNTsFactory(address(0), address(registry));
        GTokenAuthorization gtoken = new GTokenAuthorization(21_000_000 * 1e18, address(factoryV1));
        GTokenStaking staking = new GTokenStaking(address(gtoken), deployer, address(registry));
        MySBT mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        gtoken.setMySBT(address(mysbt));

        // COMMUNITY role for the deployer (the operator community)
        gtoken.mint(deployer, 2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        registry.registerRole(
            ROLE_COMMUNITY, deployer,
            abi.encode(Registry.CommunityRoleData({name: "AAStar", ensName: "aastar.eth", stakeAmount: 30 ether}))
        );
        factoryV1.deployxPNTsToken("AAStar PNTs", "aPNTs", "GlobalHub", "local.eth", 1e18, address(0));
        xPNTsToken apnts = xPNTsToken(factoryV1.getTokenAddress(deployer));

        // SuperPaymaster 5.5.0 (profile.default artifact) behind a UUPS proxy
        address spImpl = _deployDefault("SuperPaymaster", abi.encode(EP_V07, address(registry), priceFeed));
        SuperPaymaster sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            spImpl, abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 4200))
        ))));

        V55Stack memory v55;
        v55 = _ensureV55Stack(v55, address(sp), address(registry), deployer);

        registry.setSuperPaymaster(address(sp));
        factoryV1.setSuperPaymasterAddress(address(sp));
        apnts.setSuperPaymasterAddress(address(sp));
        _wireSPFactory(address(sp), v55.factory);
        sp.updatePrice();
        // EntryPoint deposit (ETH) — the prefund source. Stake is added by the harness per case (B9).
        sp.deposit{value: 10 ether}();

        registry.registerRole(ROLE_PAYMASTER_SUPER, deployer, "");
        address opToken = _issueV2Token(v55.factory, deployer, "AAStar xPNTs", "aXPNTs", "AAStar", "aastar.eth", 1e18);
        _configureOperatorV2(address(sp), opToken, deployer, deployer);
        // operator aPNTs balance (a0 is debited from it per op); aPNTs caps a single transfer
        apnts.approve(address(sp), type(uint256).max);
        for (uint256 i; i < 10; ++i) {
            apnts.mint(deployer, 4000 ether);
            sp.deposit(4000 ether);
        }
        vm.stopBroadcast();

        // read-back
        _verifyV55Stack(v55, address(sp), address(registry));
        _verifySPFactory(address(sp), v55.factory);
        _verifyV2Token(opToken, v55.factory, deployer, address(sp));
        _verifyOperatorV2(address(sp), deployer, opToken, deployer);
        _verifyPriceFresh(address(sp));
        require(_strEq(sp.version(), SP_V55_VERSION), "B-layer: SP is not 5.5.0");
        _requireDefaultArtifact(spImpl, "SuperPaymaster");

        string memory o = "blayer";
        vm.serializeAddress(o, "entryPoint", EP_V07);
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "gToken", address(gtoken));
        vm.serializeAddress(o, "staking", address(staking));
        vm.serializeAddress(o, "sbt", address(mysbt));
        vm.serializeAddress(o, "xPNTsFactory", address(factoryV1));
        vm.serializeAddress(o, "aPNTs", address(apnts));
        vm.serializeAddress(o, "priceFeed", priceFeed);
        vm.serializeAddress(o, "spImpl", spImpl);
        vm.serializeAddress(o, "globalTierSource", v55.tierSource);
        vm.serializeAddress(o, "aoaProtocolRegistry", v55.aoaRegistry);
        vm.serializeAddress(o, "xPNTsTokenV2Ext", v55.ext);
        vm.serializeAddress(o, "xPNTsTokenV2Impl", v55.impl);
        vm.serializeAddress(o, "xPNTsFactoryV2", v55.factory);
        vm.serializeAddress(o, "superPaymasterLens", v55.lens);
        vm.serializeAddress(o, "operator", deployer);
        vm.serializeAddress(o, "operatorToken", opToken);
        string memory json = vm.serializeAddress(o, "superPaymaster", address(sp));
        string memory out = vm.envOr("BLAYER_CONFIG_OUT", string("docs/design/aoa-balance-mode/b-layer/cases/deploy.json"));
        vm.writeFile(string.concat(vm.projectRoot(), "/", out), json);
        console.log("B-layer stack written to", out);
    }
}
