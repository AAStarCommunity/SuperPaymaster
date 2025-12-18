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

        console.log("=== SuperPaymaster V3.1.1 Full Audit (Multi-Tenant) ===");

        // 1. Wiring Checks
        console.log("\n[1. Wiring Checks]");
        console.log("Staking -> Registry: ", GTokenStaking(staking).REGISTRY() == registry);
        console.log("MySBT -> Registry:   ", MySBT(mysbt).REGISTRY() == registry);
        console.log("Factory -> Registry: ", xPNTsFactory(factory).REGISTRY() == registry);
        console.log("Factory -> SP:       ", xPNTsFactory(factory).SUPERPAYMASTER() == sp);
        console.log("aPNTs -> SP:         ", xPNTsToken(apnts).SUPERPAYMASTER_ADDRESS() == sp);
        console.log("bPNTs -> SP:         ", xPNTsToken(bpnts).SUPERPAYMASTER_ADDRESS() == sp);

        // 2. Identity Checks
        console.log("\n[2. Identity Checks]");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        console.log("Jason COMMUNITY role: ", IRegistryV3(registry).hasRole(ROLE_COMMUNITY, jason));
        console.log("Anni COMMUNITY role:  ", IRegistryV3(registry).hasRole(ROLE_COMMUNITY, anni));
        
        console.log("Jason MySBT ID:       ", MySBT(mysbt).userToSBT(jason));
        console.log("Anni MySBT ID:        ", MySBT(mysbt).userToSBT(anni));

        // 3. Operational Checks (SuperPaymaster)
        console.log("\n[3. Operational Checks]");
        {
            (,,,, , uint256 bal,,,) = SuperPaymasterV3(sp).operators(jason);
            console.log("Jason Op Balance:    ", bal);
        }
        {
            (,,,, , uint256 bal,,,) = SuperPaymasterV3(sp).operators(anni);
            console.log("Anni Op Balance:     ", bal);
        }

        // 4. Financial Checks
        console.log("\n[4. Financial Checks]");
        console.log("Jason GToken Balance: ", IERC20(gToken).balanceOf(jason) / 1e18, "GT");
        console.log("Jason aPNTs Balance:  ", IERC20(apnts).balanceOf(jason) / 1e18, "aPNTs");

        console.log("\n=== Audit Complete ===");
    }
}
