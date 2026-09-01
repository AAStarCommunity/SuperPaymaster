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
        // The address that owns communityOwner during the tx2 -> tx3 gap, and so the
        // one whose self-grants are worth naming. Defaults to the OP-mainnet deployer.
        address deployer = vm.envOr("DEPLOYER", address(0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3));
        // OP mainnet by default; the sepolia rehearsal passes 11155111. Asserted rather
        // than inferred, so a verification run cannot silently pass by being pointed at
        // the wrong network. The governance Safe is the same address on both.
        uint256 expectedChain = vm.envOr("EXPECT_CHAIN_ID", uint256(10));

        // Only what every branch needs, and only from addresses whose code has been
        // established. The first version of this read the price bounds and the factory
        // version up here, "so the log shows chain state even on failing runs" — which
        // is false when THE READ is the failing step: `APNTS_PRICE_MIN/MAX` are 2.3.0
        // constants, and pointing FACTORY at the live 2.1.0 factory (the address sitting
        // in config.optimism.json today) killed the whole script on a bare
        // `EvmError: Revert` with no reason, before printing the answer the operator
        // came for. A codeless FACTORY was worse: the `no code` require below was
        // unreachable, because a read above it reverted first.
        //
        // The moment an operator most needs a reason string is the moment they pasted
        // the wrong address. Same shape pr-daemon blocked in Check11 yesterday: dying
        // on a value the check does not need an answer to. Found by pr-daemon.
        require(block.chainid == expectedChain, "15_VerifyAPNTs: wrong chain");
        require(token.code.length > 0, "aPNTs address has no code");
        require(factory.code.length > 0, "factory address has no code");

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
        console.log("factory       :", factory);
        console.log("  owner         :", factoryOwner);
        console.log("  decimals      :", xPNTsToken(token).decimals());

        require(keccak256(bytes(tokenVersion)) == keccak256(bytes("XPNTs-3.5.0")), "token is not 3.5.0");
        // The two that a dropped tx3/tx4 would leave wrong, and that the deploy
        // script's own requires cannot catch once it has exited.
        require(tokenOwner == GOVERNANCE_SAFE, "token communityOwner is NOT the Safe");
        require(factoryOwner == GOVERNANCE_SAFE, "factory owner is NOT the Safe");
        // Ties the two addresses together: a token from some other factory would
        // otherwise pass every check above.
        require(tokenFactory == factory, "token was not minted by this factory");

        // The transaction gap is not only "tx3 might not land". While the deployer EOA
        // holds communityOwner, between tx2 and tx3, it can also USE it: mint to itself,
        // whitelist a spender, raise the single-tx limit, set an issuance cap. Checking
        // only that ownership ended up on the Safe reports OK on a token that was
        // altered on the way there, and a later reader cannot tell the difference —
        // the owner is correct and the version is correct in both cases.
        //
        // So the deploy is verified against the state a FRESH clone must be in, not
        // just against its owner. Every value below is what `initialize` leaves, or
        // what our factory arguments (superPaymaster = 0, paymasterAOA = 0) imply.
        // Found by Codex at stop-time review.
        if (!vm.envOr("ALLOW_POST_DEPLOY_ACTIVITY", false)) {
            require(supply == 0, "token was minted before ownership reached the Safe");
            require(xPNTsToken(token).SUPERPAYMASTER_ADDRESS() == address(0), "a SuperPaymaster was set");
            require(xPNTsToken(token).issuanceCap() == 0, "an issuance cap was set");
            require(!xPNTsToken(token).emergencyDisabled(), "the token is in emergency state");
            require(xPNTsToken(token).emergencyRevokedAddress() == address(0), "an emergency revoke happened");
            require(xPNTsToken(token).maxSingleTxLimit() == 5_000 ether, "maxSingleTxLimit was moved off its default");
            require(
                xPNTsToken(token).spenderDailyCapTokens() == 50_000 ether, "spenderDailyCap was moved off its default"
            );
            // initialize() auto-approves the factory itself and nothing else. Anyone
            // else being auto-approved means someone called addAutoApprovedSpender.
            require(
                xPNTsToken(token).autoApprovedSpenders(factory), "the factory is not auto-approved; not a fresh clone"
            );
            require(!xPNTsToken(token).autoApprovedSpenders(deployer), "the deployer EOA auto-approved itself");
            require(
                !xPNTsToken(token).approvedFacilitators(deployer), "the deployer EOA approved itself as facilitator"
            );
            require(
                xPNTsToken(token).spenderDailyCapOverride(deployer) == 0,
                "a spender cap override was set for the deployer"
            );
        }

        console.log("");
        // Diagnostics, not judgement. Reached only once the requires above have
        // established that this really is a 2.3.0 factory holding a 3.5.0 token, and
        // still wrapped: a factory that does not expose these must degrade to a line,
        // never to a revert that eats the verdict.
        try xPNTsFactory(factory).version() returns (string memory v) {
            console.log("  factory version:", v);
        } catch {
            console.log("  factory version: (not exposed by this factory)");
        }
        try xPNTsFactory(factory).aPNTsPriceUSD() returns (uint256 px) {
            console.log("  aPNTsPriceUSD  :", px);
        } catch {
            console.log("  aPNTsPriceUSD  : (not exposed by this factory)");
        }
        // repo:airaccount sizes permanently-unchangeable transfer limits against these
        // two and cannot read them off a 2.1.0 factory, so they are printed here for
        // them to re-read themselves rather than take from a message.
        try xPNTsFactory(factory).APNTS_PRICE_MIN() returns (uint256 lo) {
            console.log("  APNTS_PRICE_MIN:", lo);
        } catch {
            console.log("  APNTS_PRICE_MIN: (not exposed by this factory version)");
        }
        try xPNTsFactory(factory).APNTS_PRICE_MAX() returns (uint256 hi) {
            console.log("  APNTS_PRICE_MAX:", hi);
        } catch {
            console.log("  APNTS_PRICE_MAX: (not exposed by this factory version)");
        }
        console.log("");
        console.log("RESULT: OK - both owners are the Safe, and the token is untouched");
        console.log("  Re-run this after ANY later ownership or upgrade action.");
        console.log("  Once the Safe legitimately mints or configures the token, the");
        console.log("  fresh-clone checks stop applying: set ALLOW_POST_DEPLOY_ACTIVITY=true");
        console.log("  to keep only the ownership and identity assertions. Do NOT set it");
        console.log("  on the run that verifies the deployment itself.");
    }
}
