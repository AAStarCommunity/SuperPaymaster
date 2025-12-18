// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/MySBT.sol";

contract Check03_MySBT is Script {
    function run(address sbtAddr) external view {
        MySBT sbt = MySBT(sbtAddr);
        console.log("--- MySBT Check ---");
        console.log("Address:", sbtAddr);
        console.log("GToken Address (Immutable):", sbt.GTOKEN());
        console.log("GTokenStaking Address (Immutable):", sbt.GTOKEN_STAKING());
        console.log("Registry Address:", sbt.REGISTRY());
        console.log("DAO Multisig:", sbt.daoMultisig());
        console.log("Next Token ID:", sbt.nextTokenId());
        console.log("Version:", sbt.versionString());
        console.log("--------------------");
    }
}
