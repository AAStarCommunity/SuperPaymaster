// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/xPNTsFactory.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/core/GTokenStaking.sol";

contract Check08_Wiring is Script {
    function run(
        address factoryAddr,
        address spAddr,
        address apntsAddr,
        address mysbtAddr,
        address stakingAddr,
        address registryAddr
    ) external view {
        console.log("--- Wiring Check ---");
        
        // Factory -> SP
        address factorySP = xPNTsFactory(factoryAddr).SUPERPAYMASTER();
        console.log("Factory -> SP OK:", factorySP == spAddr);
        console.log("Stored Factory SP:", factorySP);
        
        // Token -> SP
        address tokenSP = xPNTsToken(apntsAddr).SUPERPAYMASTER_ADDRESS();
        console.log("Token -> SP OK:", tokenSP == spAddr);
        console.log("Stored Token SP:", tokenSP);
        
        // MySBT -> Registry
        address sbtReg = MySBT(mysbtAddr).REGISTRY();
        console.log("MySBT -> Registry OK:", sbtReg == registryAddr);
        console.log("Stored MySBT Registry:", sbtReg);
        
        // Staking -> Registry
        address stakingReg = GTokenStaking(stakingAddr).REGISTRY();
        console.log("Staking -> Registry OK:", stakingReg == registryAddr);
        console.log("Stored Staking Registry:", stakingReg);
        
        console.log("--------------------");
    }
}
