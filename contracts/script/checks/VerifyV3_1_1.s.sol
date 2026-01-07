// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Registry} from "src/core/Registry.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {xPNTsFactory} from "src/tokens/xPNTsFactory.sol";
import {xPNTsToken} from "src/tokens/xPNTsToken.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IERC20} from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import {Paymaster} from "src/paymasters/v4/Paymaster.sol";
import {ISuperPaymasterRegistry} from "src/interfaces/ISuperPaymasterRegistry.sol";
import {IVersioned} from "src/interfaces/IVersioned.sol";

contract VerifyV3_1_1 is Script {
    using stdJson for string;

    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);

        address deployerAddr = vm.addr(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        try vm.envAddress("DEPLOYER_ADDRESS") returns (address d) { deployerAddr = d; } catch {}
        
        address testUser = address(0xEcAACb915f7D92e9916f449F7ad42BD0408733c9); 

        address gToken = _loadAddr(json, ".gToken");
        address staking = _loadAddr(json, ".staking");
        address mysbt = _loadAddr(json, ".sbt");
        address registry = _loadAddr(json, ".registry");
        address factory = _loadAddr(json, ".xPNTsFactory");
        address apnts = _loadAddr(json, ".aPNTs");
        address sp = _loadAddr(json, ".superPaymaster");
        address pmV4 = _loadAddr(json, ".paymasterV4Impl");

        console.log("=== SuperPaymaster V3.1.1 Full Audit (Standardized) ===");

        console.log("\n[1. Wiring & Deep Init Checks]");
        
        // Staking Checks
        console.log("--- GTokenStaking (Deep) ---");
        console.log("  Staking Registry wired: ", GTokenStaking(staking).REGISTRY() == registry);
        console.log("  Staking GToken correct:  ", address(GTokenStaking(staking).GTOKEN()) == gToken);
        console.log("  Staking Owner correct:   ", GTokenStaking(staking).owner() == deployerAddr);

        // MySBT Checks
        console.log("--- MySBT (Deep) ---");
        console.log("  MySBT Registry wired:   ", MySBT(mysbt).REGISTRY() == registry);
        console.log("  MySBT GToken correct:    ", MySBT(mysbt).GTOKEN() == gToken);
        console.log("  MySBT Staking correct:   ", MySBT(mysbt).GTOKEN_STAKING() == staking);

        // Registry Checks
        console.log("--- Registry (Deep) ---");
        console.log("  Registry Staking wired:  ", address(Registry(registry).GTOKEN_STAKING()) == staking);
        console.log("  Registry MySBT wired:    ", address(Registry(registry).MYSBT()) == mysbt);

        // Factory & Token Checks
        console.log("--- Factory & Tokens (Deep) ---");
        if (factory != address(0)) {
            console.log("  Factory Registry wired:  ", xPNTsFactory(factory).REGISTRY() == registry);
            console.log("  Factory SP wired:        ", xPNTsFactory(factory).SUPERPAYMASTER() == sp);
        }
        if (apnts != address(0)) {
            console.log("  aPNTs SP wired:          ", xPNTsToken(apnts).SUPERPAYMASTER_ADDRESS() == sp);
        }

        // Paymaster V4 Checks
        if (pmV4 != address(0)) {
            console.log("--- Paymaster V4 (Deep) ---");
            console.log("  V4 Registry wired:      ", address(Paymaster(payable(pmV4)).registry()) == registry);
        }

        // 2. Identity Checks
        console.log("\n[2. Identity Checks]");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        console.log("Deployer COMMUNITY role: ", IRegistry(registry).hasRole(ROLE_COMMUNITY, deployerAddr));
        console.log("Deployer MySBT ID:       ", MySBT(mysbt).userToSBT(deployerAddr));

        // 3. Operational Checks (SuperPaymaster)
        console.log("\n[3. Operational Checks (SuperPaymaster)]");
        {
            (uint128 bal,,,,,,,,,) = SuperPaymaster(sp).operators(deployerAddr);
            console.log("Deployer Op Balance (aPNTs):", uint256(bal) / 1e18, "aPNTs");
            console.log("SP Price Staleness Threshold:", SuperPaymaster(sp).priceStalenessThreshold());
        }

        console.log("\n[4. Version Verification]");
        _logVersion("Registry", registry);
        _logVersion("GToken", gToken);
        _logVersion("Staking", staking);
        _logVersion("MySBT", mysbt);
        _logVersion("SuperPaymaster", sp);
        _logVersion("PaymasterV4Impl", pmV4);

        console.log("\n=== Audit Complete ===");
    }

    function _logVersion(string memory name, address addr) internal view {
        if (addr == address(0)) {
            console.log(string.concat(name, ": [Not Deployed]"));
            return;
        }
        try IVersioned(addr).version() returns (string memory v) {
            console.log(string.concat(name, ": ", v));
        } catch {
            console.log(string.concat(name, ": [version() check failed]"));
        }
    }

    function _loadAddr(string memory json, string memory key) internal view returns (address) {
        if (bytes(json).length < 2) return address(0);
        try vm.parseJsonAddress(json, key) returns (address a) {
            if (a.code.length > 0) return a;
        } catch {}
        return address(0);
    }
}