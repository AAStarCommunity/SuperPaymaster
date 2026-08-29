// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";

/**
 * @title VendoredProvenanceSelfCheck
 * @notice Makes `contracts/test/crossrepo/vendor/`'s provenance headers TESTED claims
 *         instead of prose.
 *
 * @dev    CC-115 B2 follow-up. `CC115CrossRepoConformance` says it runs SP's release gates
 *         against "the REAL merged DVT verifier", and the only thing backing that phrase is
 *         a sha256 written in a comment. Before this suite existed that number appeared
 *         exactly ONCE in the whole repository — inside the header asserting it — and no CI
 *         step referenced `crossrepo/` at all. So the failure mode was the same disease the
 *         cross-repo suite was written to cure: the copy drifts, every test stays green, and
 *         the claim "this is upstream's code" quietly stops being true. It is a nastier
 *         version than the `MockVerifier` it replaced, because a mock is obviously not the
 *         real thing from day one, whereas a vendored copy becomes untrue GRADUALLY while
 *         the header keeps naming a commit.
 *
 *         What this file can and cannot do:
 *           - CAN, offline, with no new infrastructure: re-run each header's own recipe
 *             ("strip N header lines, reverse the one declared deviation, sha256 the rest")
 *             and require the result to equal the upstream digest the header names. That
 *             catches any local edit to a vendored BODY. The header is NOT covered by
 *             that recipe — it is stripped before hashing — so the whole file is pinned
 *             separately below; without that, re-pointing a header at another commit
 *             while leaving the code alone would pass every body assertion here.
 *           - CANNOT: notice that UPSTREAM moved. That needs the network, so it lives in
 *             `scripts/check-vendored-drift.sh` and is a release-gate step, not a unit test.
 *             Running only this file does NOT establish freshness — see the script's own
 *             notes and treat a skipped/failed network check as UNRESOLVED, never as clean
 *             (`docs/security/CC48-safe-onboarding-runbook.md` §5b applies verbatim).
 *
 *         Kept in the test suite rather than only in CI deliberately: a CI step can be
 *         skipped, reordered or made conditional, while this runs wherever the suite runs.
 */
contract VendoredProvenanceSelfCheck is Test {
    string internal constant VERIFIER_PATH = "contracts/test/crossrepo/vendor/OverIssueFraudProofVerifier.sol";
    string internal constant IFACE_PATH = "contracts/test/crossrepo/vendor/IFraudProofVerifier.sol";

    /// @dev DVT master @ 8395c94c, sha256 of contracts/src/verifiers/OverIssueFraudProofVerifier.sol
    bytes32 internal constant VERIFIER_UPSTREAM_SHA =
        0x6616d5a70af6bd4dedd1982d5874376c014430cdad8af1e0e461bdb120af33ec;
    /// @dev DVT master @ 8395c94c, sha256 of contracts/src/interfaces/IFraudProofVerifier.sol
    bytes32 internal constant IFACE_UPSTREAM_SHA =
        0x4d96d411af30e4d384232f48743f0b31f70e1bb3afd16af5e64f16a4421dbe65;

    uint256 internal constant VERIFIER_HEADER_LINES = 11;
    uint256 internal constant IFACE_HEADER_LINES = 8;

    /// @dev sha256 of the vendored files EXACTLY as they sit here, header included. The
    ///      upstream digests above are computed on the STRIPPED body, so on their own they
    ///      say nothing about the header — and the header is where the provenance claim
    ///      lives. Updating a vendored copy has to touch these constants deliberately.
    bytes32 internal constant VERIFIER_FILE_SHA =
        0x1e5fd65daf17fba09cfe3d6ad548c2cb116462284941f1d9db832c79f0f4e875;
    bytes32 internal constant IFACE_FILE_SHA =
        0x730c30c56622e6cd82769bf252b47ad9f50bac5f17c2f7e68af049367418c17a;

    /// @dev The single declared deviation in the verifier copy: both vendored files sit side
    ///      by side here, so the interface import is relative to this directory instead of
    ///      upstream's src/interfaces. Reversing it must reproduce upstream byte-for-byte.
    string internal constant LOCAL_IMPORT = 'import {IFraudProofVerifier} from "./IFraudProofVerifier.sol";';
    string internal constant UPSTREAM_IMPORT =
        'import {IFraudProofVerifier} from "../interfaces/IFraudProofVerifier.sol";';

    /// The header is part of the claim, so pin the whole file too. The body assertions
    /// strip the header before hashing and are blind to it by construction; editing the
    /// recorded commit while leaving the code untouched is caught HERE and nowhere else.
    function test_VendoredFilesAreByteExactIncludingTheirHeaders() public view {
        assertEq(sha256(bytes(vm.readFile(VERIFIER_PATH))), VERIFIER_FILE_SHA, "vendored verifier file edited");
        assertEq(sha256(bytes(vm.readFile(IFACE_PATH))), IFACE_FILE_SHA, "vendored interface file edited");
    }

    /// The interface copy declares NO deviation, so stripping its header alone must
    /// reproduce upstream exactly. If someone "fixes" a comment in it, this goes red.
    function test_VendoredInterfaceStillHashesToUpstream() public view {
        bytes memory body = _stripLines(bytes(vm.readFile(IFACE_PATH)), IFACE_HEADER_LINES);
        assertEq(
            sha256(body),
            IFACE_UPSTREAM_SHA,
            "vendored IFraudProofVerifier no longer reproduces the upstream digest its header names"
        );
    }

    /// The verifier copy declares exactly one deviation. Reverse precisely that, and the
    /// result must be upstream. A second, undeclared deviation therefore fails here — which
    /// is the whole reason the header states the deviation in reversible form ("from X to Y")
    /// rather than as "some necessary path adjustments".
    function test_VendoredVerifierStillHashesToUpstreamOnceTheDeclaredDeviationIsReversed() public view {
        bytes memory body = _stripLines(bytes(vm.readFile(VERIFIER_PATH)), VERIFIER_HEADER_LINES);
        bytes memory restored = _replaceOnce(body, bytes(LOCAL_IMPORT), bytes(UPSTREAM_IMPORT));
        assertEq(
            sha256(restored),
            VERIFIER_UPSTREAM_SHA,
            "vendored OverIssueFraudProofVerifier no longer reproduces upstream once its one declared deviation is reversed"
        );
    }

    /// The declared header length is itself part of the recipe, so pin it: stripping one
    /// line too few or too many must NOT produce the upstream digest. Without this, a header
    /// could grow or shrink and the recipe would silently describe a different file.
    function test_HeaderLineCountsArePinnedNotApproximate() public view {
        bytes memory raw = bytes(vm.readFile(VERIFIER_PATH));
        for (uint256 off = 1; off <= 2; ++off) {
            assertTrue(
                sha256(_replaceOnce(_stripLines(raw, VERIFIER_HEADER_LINES - off), bytes(LOCAL_IMPORT), bytes(UPSTREAM_IMPORT)))
                    != VERIFIER_UPSTREAM_SHA,
                "stripping FEWER lines than declared must not also match"
            );
            assertTrue(
                sha256(_replaceOnce(_stripLines(raw, VERIFIER_HEADER_LINES + off), bytes(LOCAL_IMPORT), bytes(UPSTREAM_IMPORT)))
                    != VERIFIER_UPSTREAM_SHA,
                "stripping MORE lines than declared must not also match"
            );
        }
    }

    /// The reversal must be load-bearing: leaving the local import in place must NOT hash to
    /// upstream. Otherwise the previous test could be passing for the wrong reason.
    function test_ReversingTheDeviationIsWhatMakesItMatch() public view {
        bytes memory body = _stripLines(bytes(vm.readFile(VERIFIER_PATH)), VERIFIER_HEADER_LINES);
        assertTrue(
            sha256(body) != VERIFIER_UPSTREAM_SHA,
            "the un-reversed body must differ from upstream, or the deviation is not real"
        );
    }

    // ---- helpers ----

    /// @dev Everything after the first `n` newlines. Reverts if the file has fewer.
    function _stripLines(bytes memory src, uint256 n) internal pure returns (bytes memory out) {
        uint256 seen;
        uint256 i;
        for (; i < src.length && seen < n; ++i) {
            if (src[i] == 0x0a) ++seen;
        }
        require(seen == n, "fewer lines than the declared header");
        out = new bytes(src.length - i);
        for (uint256 k = 0; k < out.length; ++k) {
            out[k] = src[i + k];
        }
    }

    /// @dev Replace the first occurrence of `needle`. Reverts when absent, so a renamed or
    ///      re-edited import cannot silently degrade into "no replacement performed".
    function _replaceOnce(bytes memory hay, bytes memory needle, bytes memory rep)
        internal
        pure
        returns (bytes memory out)
    {
        uint256 at = type(uint256).max;
        for (uint256 i = 0; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) { hit = false; break; }
            }
            if (hit) { at = i; break; }
        }
        require(at != type(uint256).max, "declared deviation not found in the vendored file");
        out = new bytes(hay.length - needle.length + rep.length);
        uint256 p;
        for (uint256 i = 0; i < at; ++i) out[p++] = hay[i];
        for (uint256 i = 0; i < rep.length; ++i) out[p++] = rep[i];
        for (uint256 i = at + needle.length; i < hay.length; ++i) out[p++] = hay[i];
    }
}
