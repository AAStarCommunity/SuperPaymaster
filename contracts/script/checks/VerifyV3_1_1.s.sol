// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Registry} from "src/core/Registry.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {xPNTsFactory} from "src/tokens/xPNTsFactory.sol";
import {xPNTsToken} from "src/tokens/xPNTsToken.sol";
import {SuperPaymasterV3} from "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import {IRegistryV3} from "src/interfaces/v3/IRegistryV3.sol";
import {IERC20} from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import {PaymasterV4_1} from "src/paymasters/v4/PaymasterV4_1.sol";
import {ISuperPaymasterRegistry} from "src/interfaces/ISuperPaymasterRegistry.sol";
import {IVersioned} from "src/interfaces/IVersioned.sol";

contract VerifyV3_1_1 is Script {
    using stdJson for string;

    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFileName = vm.envOr("CONFIG_FILE", string("config.json"));
        string memory path = string.concat(root, "/", configFileName);
        string memory json = vm.readFile(path);

        address jason = 0xb5600060e6de5E11D3636731964218E53caadf0E; // Keep hardcoded or load from env?
        // Jason/Anni addresses might be test specific. Leaving hardcoded for now or env?
        // Use env for Jason if possible, or fallback.
        try vm.envAddress("DEPLOYER_ADDRESS") returns (address d) { jason = d; } catch {}
        
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9; // Test user

        address gToken = _loadAddr(json, ".gToken");
        address staking = _loadAddr(json, ".staking");
        address mysbt = _loadAddr(json, ".sbt");
        address registry = _loadAddr(json, ".registry");
        // factory -> xPNTsFactory
        address factory = _loadAddr(json, ".xPNTsFactory");
        address apnts = _loadAddr(json, ".aPNTs");
        // bpnts is usually a second test token, might not be in config if not deployed by full script.
        // If not in config, use 0 or skip check.
        address bpnts = address(0); // _loadAddr(json, ".bPNTs"); 
        
        address sp = _loadAddr(json, ".superPaymaster");
        // pmV4 -> paymasterV4Proxy or paymasterV4? Script usually means Proxy for functional check.
        address pmV4 = _loadAddr(json, ".paymasterV4Proxy");
        if (pmV4 == address(0)) pmV4 = _loadAddr(json, ".paymasterV4"); // Fallback

        console.log("=== SuperPaymaster V3.1.1 Full Audit (Multi-Tenant) ===");

        console.log("\n[1. Wiring & Deep Init Checks]");
        
        // Staking Checks
        console.log("--- GTokenStaking (Deep) ---");
        console.log("  Staking Registry wired: ", GTokenStaking(staking).REGISTRY() == registry);
        console.log("  Staking GToken correct:  ", address(GTokenStaking(staking).GTOKEN()) == gToken);
        console.log("  Staking Owner correct:   ", GTokenStaking(staking).owner() == jason);
        console.log("  Staking Treasury correct:", GTokenStaking(staking).treasury() == jason);

        // MySBT Checks
        console.log("--- MySBT (Deep) ---");
        console.log("  MySBT Registry wired:   ", MySBT(mysbt).REGISTRY() == registry);
        console.log("  MySBT GToken correct:    ", MySBT(mysbt).GTOKEN() == gToken);
        console.log("  MySBT Staking correct:   ", MySBT(mysbt).GTOKEN_STAKING() == staking);
        console.log("  MySBT DAO/Owner correct: ", MySBT(mysbt).daoMultisig() == jason);

        // Registry Checks
        console.log("--- Registry (Deep) ---");
        console.log("  Registry Staking wired:  ", address(Registry(registry).GTOKEN_STAKING()) == staking);
        console.log("  Registry MySBT wired:    ", address(Registry(registry).MYSBT()) == mysbt);
        console.log("  Registry Owner correct:  ", Registry(registry).owner() == jason);

        // Factory & Token Checks
        // Factory & Token Checks
        console.log("--- Factory & Tokens (Deep) ---");
        if (factory != address(0)) {
            console.log("  Factory Registry wired:  ", xPNTsFactory(factory).REGISTRY() == registry);
            console.log("  Factory SP wired:        ", xPNTsFactory(factory).SUPERPAYMASTER() == sp);
        }
        if (apnts != address(0)) {
            console.log("  aPNTs SP wired:          ", xPNTsToken(apnts).SUPERPAYMASTER_ADDRESS() == sp);
        }
        if (bpnts != address(0)) {
            console.log("  bPNTs SP wired:          ", xPNTsToken(bpnts).SUPERPAYMASTER_ADDRESS() == sp);
        }

        // Paymaster V4 Checks
        if (pmV4 != address(0)) {
            console.log("--- Paymaster V4 AOA Mode (Deep) ---");
            console.log("  V4 Registry wired:      ", PaymasterV4_1(payable(pmV4)).registry() == ISuperPaymasterRegistry(registry));
            console.log("  V4 MySBT wired:         ", PaymasterV4_1(payable(pmV4)).isSBTSupported(mysbt));
            if (bpnts != address(0)) {
                console.log("  V4 bPNTs wired:         ", PaymasterV4_1(payable(pmV4)).isGasTokenSupported(bpnts));
            }
        }
        // 2. Identity Checks
        console.log("\n[2. Multi-Tenant Identity Checks]");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        console.log("Jason COMMUNITY role:    ", IRegistryV3(registry).hasRole(ROLE_COMMUNITY, jason));
        console.log("Anni COMMUNITY role:     ", IRegistryV3(registry).hasRole(ROLE_COMMUNITY, anni));
        
        console.log("Jason MySBT ID:          ", MySBT(mysbt).userToSBT(jason));
        console.log("Anni MySBT ID:           ", MySBT(mysbt).userToSBT(anni));

        // 3. Operational Checks (SuperPaymaster)
        console.log("\n[3. Operational Checks (SuperPaymaster)]");
        {
            (uint128 bal,,,,,,,,,) = SuperPaymasterV3(sp).operators(jason);
            console.log("Jason Op Balance (aPNTs):", uint256(bal) / 1e18, "aPNTs");
        }
        {
            (uint128 bal,,,,,,,,,) = SuperPaymasterV3(sp).operators(anni);
            console.log("Anni Op Balance (aPNTs): ", uint256(bal));
        }

        // 4. Financial Checks
        console.log("\n[4. Financial Checks]");
        console.log("Jason GToken Balance:    ", IERC20(gToken).balanceOf(jason) / 1e18, "GT");
        console.log("Jason aPNTs Balance:     ", IERC20(apnts).balanceOf(jason) / 1e18, "aPNTs");
        console.log("Anni GToken Balance:     ", IERC20(gToken).balanceOf(anni) / 1e18, "GT");

        console.log("\n[5. Version Verification]");
        _logVersion("Registry", registry);
        _logVersion("GToken", gToken);
        _logVersion("Staking", staking);
        _logVersion("MySBT", mysbt);
        _logVersion("xPNTsFactory", factory);
        _logVersion("SuperPaymaster", sp);
        _logVersion("PaymasterV4", pmV4);
        _logVersion("aPNTs", apnts);
        _logVersion("ReputationSystem", _loadAddr(json, ".reputationSystem"));
        _logVersion("BLSAggregator", _loadAddr(json, ".blsAggregator"));
        _logVersion("BLSValidator", _loadAddr(json, ".blsValidator"));
        _logVersion("DVTValidator", _loadAddr(json, ".dvtValidator"));

        console.log("\n=== Master Audit Complete ===");
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
