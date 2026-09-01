// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {xPNTsFactory} from "src/tokens/xPNTsFactory.sol";
import {xPNTsToken} from "src/tokens/xPNTsToken.sol";

/**
 * @title 14_RedeployAPNTs
 * @notice Replace the OP-mainnet aPNTs with a governed one.
 *
 * @dev    WHAT THIS DOES AND DOES NOT FIX. It changes WHO may mint, not WHETHER minting
 *         is bounded. `XPNTs-3.5.0` carries `issuanceCap`, but that is not a mint gate:
 *         there is one `_mint` call site, guarded only by `onlyFactoryOrOwner`, and
 *         `issuanceCap` is read in exactly one place — the view `isOverIssued()` that DVT
 *         calls. It defaults to zero (unset) and is set afterwards by `communityOwner`.
 *         So the Safe can still mint without bound; it just cannot do so unilaterally,
 *         and over-issuance becomes visible instead of silent. Calling the result
 *         "capped" would be claiming an enforcement that is not in the code.
 *
 * @dev    WHY A NEW TOKEN AND NOT A FIX.
 *
 *         The live OP-mainnet aPNTs (0x0B41C780…) is `XPNTs-3.0.0-unlimited` and its
 *         `communityOwner` is the deployer EOA 0x51Ac6949…, which can mint without
 *         bound — simulated at 1e24, seven times the 140,000 supply, with a non-owner
 *         call as the control. It is an EIP-1167 clone: the implementation address is
 *         hard-coded in its runtime bytecode, so there is no upgrade path. The version
 *         and the owner can only change together, in a new deployment. repo:airaccount
 *         is waiting on that and declined to reference the current address.
 *
 *         WHY A NEW FACTORY TOO. `xPNTsFactory.implementation` is immutable, built in
 *         the constructor. The live factory (2.1.0, 0x864971a2…) is welded to the
 *         3.0.0-unlimited implementation, so a 3.5.0 clone requires a new factory.
 *
 *         WHY SUPERPAYMASTER IS address(0) HERE. Passing an SP makes the factory call
 *         `setSuperPaymasterAddress` and `addAutoApprovedSpender` on the fresh token at
 *         birth. OP mainnet still runs SuperPaymaster-3.2.2 on Registry-3.0.2 — a
 *         pre-P0-3 stack whose own `BLS_AGGREGATOR` reads zero. Auto-approving a spender
 *         is not something to do by default on a token nobody is using yet; both
 *         setters remain callable by `communityOwner` (the Safe) once OP mainnet moves
 *         to V5, so this is the reversible direction and pre-approving is not.
 *
 *         The 3.5.0 token makes no runtime calls into Registry or SuperPaymaster — the
 *         CC-28 issuance-cap model lives in the factory — so it is self-contained on the
 *         V3 stack that is there today.
 *
 *         OWNERSHIP. `deployxPNTsToken` sets `communityOwner = msg.sender`; it takes no
 *         owner argument. The EOA is therefore the owner for the span of one call, which
 *         is why the transfer is in the same script and the run asserts the end state
 *         rather than trusting it. The EOA is also the only address holding the
 *         COMMUNITY role on the OP-mainnet Registry, so it has to be the caller.
 *
 * Run (needs an OP-mainnet RPC in .env.optimism; DEPLOYER_ACCOUNT=optimism-deployer):
 *   forge script contracts/script/deployment/14_RedeployAPNTs.s.sol:RedeployAPNTs \
 *     --rpc-url "$RPC_URL" --account optimism-deployer --broadcast --verify
 */
contract RedeployAPNTs is Script {
    // Mycelium community Safe, same address on sepolia / ethereum / optimism.
    address constant GOVERNANCE_SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    // OP-mainnet Registry-3.0.2. Only used for the factory's COMMUNITY-role gate.
    address constant OP_REGISTRY = 0x997686219F31405503D32728B1f094F115EF24e7;
    address constant OLD_APNTS = 0x0B41C78081B5A141eb4C3C7E7FD8E58A7Bde553B;

    // Mirrors the live token exactly, read off chain 2026-09-01.
    string constant TOKEN_NAME = "AAStar PNTs";
    string constant TOKEN_SYMBOL = "aPNTs";
    string constant COMMUNITY_NAME = "AAStar";
    string constant COMMUNITY_ENS = "aastar.eth";
    uint256 constant EXCHANGE_RATE = 1e18;

    function run() external {
        require(block.chainid == 10, "14_RedeployAPNTs: OP mainnet only");
        require(GOVERNANCE_SAFE.code.length > 0, "governance Safe has no code on this chain");

        vm.startBroadcast();

        xPNTsFactory factory = new xPNTsFactory(address(0), OP_REGISTRY);
        address token = factory.deployxPNTsToken(
            TOKEN_NAME, TOKEN_SYMBOL, COMMUNITY_NAME, COMMUNITY_ENS, EXCHANGE_RATE, address(0)
        );
        xPNTsToken(token).transferCommunityOwnership(GOVERNANCE_SAFE);

        vm.stopBroadcast();

        // The point of the whole exercise, asserted rather than reported: an EOA must
        // not be able to mint this token when the script is done.
        require(
            keccak256(bytes(xPNTsToken(token).version())) == keccak256(bytes("XPNTs-3.5.0")), "new token is not 3.5.0"
        );
        require(xPNTsToken(token).communityOwner() == GOVERNANCE_SAFE, "owner did not land on the Safe");
        require(token != OLD_APNTS, "sanity: address collision with the old token");

        console.log("--- aPNTs redeploy, OP mainnet ---");
        console.log("factory      :", address(factory), factory.version());
        console.log("implementation:", factory.implementation());
        console.log("aPNTs (new)  :", token, xPNTsToken(token).version());
        console.log("communityOwner:", xPNTsToken(token).communityOwner());
        console.log("aPNTs (old)  :", OLD_APNTS, "-- leave in place, do not migrate supply here");
        console.log("");
        console.log("NEXT, not done by this script:");
        console.log("  1. config.optimism.json: aPNTs + xPNTsFactory -> the addresses above");
        console.log("  2. tell repo:airaccount the new address (they are blocked on it)");
        console.log("  3. the 140,000 old-token supply is NOT carried over; decide on");
        console.log("     migration separately, from the Safe");
        console.log("  4. Safe calls setIssuanceCap(...) — the cap is UNSET until it does,");
        console.log("     and it is a view for DVT, never a mint gate");
        console.log("  5. when OP mainnet reaches V5: Safe calls setSuperPaymasterAddress");
        console.log("     and addAutoApprovedSpender");
    }
}
