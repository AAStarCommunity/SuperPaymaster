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
        
        address gToken = 0x4eEF13E130fA5f2aA17089aEf2754234f49f1D49;
        address staking = 0x462037Cf25dBCD414EcEe8f93475fE6cdD8b23c2;
        address mysbt = 0x4f2F35899acE188C1d31b27e19B38D56AA86e8e2;
        address registry = 0xBD936920F40182f5C80F0Ee2Ffc0de6bc2Ae12c8;
        address factory = 0x52cC246cc4f4c49e2BAE98b59241b30947bA6013;
        address apnts = 0x55aB6Ea95fE74c9116AaA634caBC2E774C90d3fa;
        address bpnts = 0xa12C8B032F6007E963F86Cd05Aa0D451879f65E2;
        address sp = 0x311E9024b38aFdD657dDf4F338a0492317DF6811;
        address pmV4 = 0xD16224cAE2df7A6D443f7b3Ad989E16E42650CaC;

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
        console.log("  V4 aPNTs wired:         ", PaymasterV4_1(payable(pmV4)).isGasTokenSupported(apnts));

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
