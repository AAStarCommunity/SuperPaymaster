// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {xPNTsFactory} from "src/tokens/xPNTsFactory.sol";
import {xPNTsToken} from "src/tokens/xPNTsToken.sol";

/**
 * @title 15_VerifyAPNTs
 * @notice Re-check the aPNTs redeploy AGAINST THE CHAIN, after the broadcast.
 *
 * @dev    WHY THIS IS A SEPARATE SCRIPT. The `require`s at the end of
 *         14_RedeployAPNTs run in the simulation, after `stopBroadcast` — they see
 *         the simulated post-state, not the chain. The deploy is four independent
 *         transactions, and between tx2 (deployxPNTsToken) and tx3
 *         (transferCommunityOwnership) the new token's `communityOwner` IS the
 *         deployer EOA: exactly the state the whole exercise removes. If tx3 or tx4
 *         fails or is dropped after tx1/tx2 land, nothing re-evaluates: the run has
 *         already exited 0 on a simulation, while the chain holds a half-applied
 *         deployment with an EOA owning a live token.
 *
 *         So the assertions have to be runnable again, later, reading state instead
 *         of producing it. That is this file. It is `view` — it cannot deploy, cannot
 *         broadcast, and cannot repair anything; it only refuses to agree that a
 *         partially-applied deployment is finished.
 *
 *         Raised by pr-daemon and Codex on review of 7e79a3a7.
 *
 * Run, with the two addresses 14_RedeployAPNTs printed:
 *   APNTS=0x... FACTORY=0x... forge script \
 *     contracts/script/deployment/15_VerifyAPNTs.s.sol:VerifyAPNTs \
 *     --rpc-url https://mainnet.optimism.io
 */
contract VerifyAPNTs is Script {
    address constant GOVERNANCE_SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;

    function run() external view {
        address token = vm.envAddress("APNTS");
        address factory = vm.envAddress("FACTORY");

        // Read everything first, then judge, so the log shows the actual chain state
        // even on the runs that fail.
        string memory tokenVersion = xPNTsToken(token).version();
        address tokenOwner = xPNTsToken(token).communityOwner();
        address factoryOwner = xPNTsFactory(factory).owner();
        address tokenFactory = xPNTsToken(token).FACTORY();
        uint256 supply = xPNTsToken(token).totalSupply();

        console.log("--- aPNTs redeploy, ON-CHAIN verification ---");
        console.log("chain id      :", block.chainid);
        console.log("aPNTs         :", token, tokenVersion);
        console.log("  communityOwner:", tokenOwner);
        console.log("  FACTORY       :", tokenFactory);
        console.log("  totalSupply   :", supply);
        console.log("factory       :", factory, xPNTsFactory(factory).version());
        console.log("  owner         :", factoryOwner);
        console.log("  aPNTsPriceUSD :", xPNTsFactory(factory).aPNTsPriceUSD());
        console.log("  decimals      :", xPNTsToken(token).decimals());
        // repo:airaccount sizes permanently-unchangeable transfer limits against these
        // two, and cannot read them off the 2.1.0 factory that predates P0-12. Printed
        // here so the numbers they bake come from the chain, not from a message.
        console.log("  APNTS_PRICE_MIN:", xPNTsFactory(factory).APNTS_PRICE_MIN());
        console.log("  APNTS_PRICE_MAX:", xPNTsFactory(factory).APNTS_PRICE_MAX());

        require(block.chainid == 10, "15_VerifyAPNTs: OP mainnet only");
        require(token.code.length > 0, "aPNTs address has no code");
        require(factory.code.length > 0, "factory address has no code");
        require(keccak256(bytes(tokenVersion)) == keccak256(bytes("XPNTs-3.5.0")), "token is not 3.5.0");
        // The two that a dropped tx3/tx4 would leave wrong, and that the deploy
        // script's own requires cannot catch once it has exited.
        require(tokenOwner == GOVERNANCE_SAFE, "token communityOwner is NOT the Safe");
        require(factoryOwner == GOVERNANCE_SAFE, "factory owner is NOT the Safe");
        // Ties the two addresses together: a token from some other factory would
        // otherwise pass every check above.
        require(tokenFactory == factory, "token was not minted by this factory");

        console.log("");
        console.log("RESULT: OK - both owners are the Safe, on chain, right now");
        console.log("  Re-run this after ANY later ownership or upgrade action.");
    }
}
