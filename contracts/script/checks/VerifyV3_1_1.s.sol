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

contract VerifyV3_1_1 is Script {
    function run() external view {
        address jason = 0xb5600060e6de5E11D3636731964218E53caadf0E;
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
        
        address gToken = 0xfc5671D606e8dd65EA39FB3f519443B7DAB40570;
        address staking = 0xB8C4Ed4906baF13Cb5fE49B1A985B76BAccEEC06;
        address mysbt = 0x925e2ad77CeD7b72C9e58D6BCDB2c994F705c53b;
        address registry = 0xf265d21c2cE6B2fA5d6eD1A2d7b032F03516BE19;
        address factory = 0x673928F507D791B57F06BC3f487229D9D6d5d33D;
        address apnts = 0xbC0E4c1103ffb770F3C619d60962394466433518;
        address bpnts = 0xd7036a4a98AF3586C3E6416fBFeC3c1e8b6e0575;
        address sp = 0x8289C18f7809B3B7DCe287fEb0ef7516fD30c89f;
        address pmV4 = 0xb78d77Eb3EED175F4979967181EC340fAE27b85D;

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
        console.log("--- Factory & Tokens (Deep) ---");
        console.log("  Factory Registry wired:  ", xPNTsFactory(factory).REGISTRY() == registry);
        console.log("  Factory SP wired:        ", xPNTsFactory(factory).SUPERPAYMASTER() == sp);
        console.log("  aPNTs SP wired:          ", xPNTsToken(apnts).SUPERPAYMASTER_ADDRESS() == sp);
        console.log("  bPNTs SP wired:          ", xPNTsToken(bpnts).SUPERPAYMASTER_ADDRESS() == sp);

        // Paymaster V4 Checks
        console.log("--- Paymaster V4 AOA Mode (Deep) ---");
        console.log("  V4 Registry wired:      ", PaymasterV4_1(payable(pmV4)).registry() == ISuperPaymasterRegistry(registry));
        console.log("  V4 MySBT wired:         ", PaymasterV4_1(payable(pmV4)).isSBTSupported(mysbt));
        console.log("  V4 bPNTs wired:         ", PaymasterV4_1(payable(pmV4)).isGasTokenSupported(bpnts));
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
            (,,,, , uint256 bal,,,) = SuperPaymasterV3(sp).operators(jason);
            console.log("Jason Op Balance (aPNTs):", bal / 1e18, "aPNTs");
        }
        {
            (,,,, , uint256 bal,,,) = SuperPaymasterV3(sp).operators(anni);
            console.log("Anni Op Balance (aPNTs): ", bal);
        }

        // 4. Financial Checks
        console.log("\n[4. Financial Checks]");
        console.log("Jason GToken Balance:    ", IERC20(gToken).balanceOf(jason) / 1e18, "GT");
        console.log("Jason aPNTs Balance:     ", IERC20(apnts).balanceOf(jason) / 1e18, "aPNTs");
        console.log("Anni GToken Balance:     ", IERC20(gToken).balanceOf(anni) / 1e18, "GT");

        console.log("\n=== Master Audit Complete ===");
    }
}
