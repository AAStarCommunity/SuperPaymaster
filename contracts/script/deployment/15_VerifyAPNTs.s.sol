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
        bool checkedDefaults = !vm.envOr("ALLOW_POST_DEPLOY_ACTIVITY", false);
        if (checkedDefaults) {
            // The expectation comes from the DEPLOY RECORD, not from whoever runs
            // this. It used to read MINT_AMOUNT from the environment, and the
            // natural way to answer "what should it be?" is to read the chain —
            // at which point the assertion compares the chain to itself. Same
            // family as three other defects fixed this week: an expected value
            // taken from a source that cannot disagree with the thing under test.
            // Issue #407.
            //
            // A missing record FAILS. "No record" and "record says zero" are not
            // the same reading, and treating them alike is the absence-as-consent
            // this repo has now been bitten by four times.
            string memory recPath =
                string.concat(vm.projectRoot(), "/deployments/apnts-deploy-record.", vm.toString(block.chainid), ".json");
            // vm.exists is non-view, and run() is deliberately `view` — that is what
            // makes this script unable to deploy, broadcast or repair anything.
            // Keeping the guarantee is worth more than the convenience, so a missing
            // record is caught by vm.readFile itself: measured, it REVERTS on absence
            // ("failed to open file ... No such file or directory") rather than
            // returning empty. So the require below covers only the present-but-empty
            // case; both are fail-closed, which is what matters. The earlier comment
            // here described a mechanism that does not exist. pr-daemon, #417.
            string memory rec = vm.readFile(recPath);
            require(bytes(rec).length > 0, "deploy record is empty: cannot verify supply against a declared amount");
            require(
                stdJson.readAddress(rec, ".aPNTs") == token,
                "the deploy record is for a different token than the one being verified"
            );
            require(stdJson.readUint(rec, ".chainId") == block.chainid, "the deploy record is from a different chain");
            uint256 declared = stdJson.readUint(rec, ".mintAmount");
            require(supply == declared, "supply does not equal the DECLARED mint: something else minted");
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
            // updateExchangeRate is onlyFactoryOrOwner too, and it is the divisor in
            // issuedValueUSD: a tainted rate survives a zero supply and silently
            // rescales every later over-issue verdict.
            require(xPNTsToken(token).exchangeRate() == 1 ether, "exchangeRate was moved off the deployed value");
            // The value alone false-passes. `initialize` sets `exchangeRate` but NOT
            // `exchangeRateUpdatedAt`, so a fresh clone carries zero there — and the
            // cooldown guard reads `if (exchangeRateUpdatedAt != 0 && ...)`, meaning it
            // does not apply to the first call. The EOA could therefore call
            // updateExchangeRate(1 ether) in the gap: same value, delta zero, in range,
            // and it SUCCEEDS. The rate still equals 1 ether and the check above still
            // passes, while the token has been written to and the one-hour cooldown is
            // now armed against the Safe's first legitimate rate change.
            //
            // `exchangeRateUpdatedAt` is the discriminating value: nothing but
            // updateExchangeRate ever writes it, so zero means the function was never
            // called. Found by Codex at stop-time review.
            require(xPNTsToken(token).exchangeRateUpdatedAt() == 0, "updateExchangeRate was called on this token");
            // The mappings cannot be enumerated from a view call, so this is a targeted
            // probe of one address the caller names, not a sweep. See the scope note
            // printed with the verdict.
            address probe = vm.envOr("PROBE_ADDRESS", address(0));
            if (probe != address(0)) {
                require(!xPNTsToken(token).autoApprovedSpenders(probe), "PROBE_ADDRESS is auto-approved");
                require(!xPNTsToken(token).approvedFacilitators(probe), "PROBE_ADDRESS is an approved facilitator");
                require(xPNTsToken(token).spenderDailyCapOverride(probe) == 0, "PROBE_ADDRESS has a cap override");
            }
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
        // The claim has to shrink when the checks do. ALLOW_POST_DEPLOY_ACTIVITY
        // skips the whole fresh-clone block above — including the deploy-record
        // supply comparison — and this line went on asserting the defaults anyway.
        // A green line that outlived its checks. pr-daemon/Codex, #417.
        if (checkedDefaults) {
            console.log("RESULT: OK - both owners are the Safe; every enumerable value is at");
            console.log("        its post-deploy default");
        } else {
            console.log("RESULT: OK (REDUCED) - both owners are the Safe. ALLOW_POST_DEPLOY_ACTIVITY");
            console.log("        was set: the fresh-clone defaults and the supply-vs-deploy-record");
            console.log("        comparison were NOT checked.");
        }
        console.log("");
        console.log("  WHAT THIS DOES NOT PROVE. autoApprovedSpenders, approvedFacilitators");
        console.log("  and spenderDailyCapOverride are mappings: a view call can ask about an");
        console.log("  address, it cannot enumerate them. While the deployer EOA held");
        console.log("  communityOwner between tx2 and tx3 it could have granted any of those");
        console.log("  to an ARBITRARY third address, and no later reading of this contract");
        console.log("  will show it. This probes the factory, the deployer, and PROBE_ADDRESS");
        console.log("  if given - so it can refute a grant it was told to look for, and");
        console.log("  cannot certify that none exists. An earlier version of this line said");
        console.log("  the token was untouched, which was a claim this script cannot make.");
        console.log("");
        console.log("  The complete check is the event log. A fresh deployment must show no");
        console.log("  AutoApprovedSpenderAdded beyond the factory, and no FacilitatorApproved,");
        console.log("  SpenderDailyCapForUpdated, ExchangeRateUpdated or Transfer at all.");
        console.log("  Re-run this after ANY later ownership or upgrade action.");
        console.log("  Once the Safe legitimately mints or configures the token, the");
        console.log("  fresh-clone checks stop applying: set ALLOW_POST_DEPLOY_ACTIVITY=true");
        console.log("  to keep only the ownership and identity assertions. Do NOT set it");
        console.log("  on the run that verifies the deployment itself.");
    }
}
