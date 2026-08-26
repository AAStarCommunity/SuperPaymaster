// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";

/// @notice Harness exposing the internal A' commitment helper for unit testing.
contract CommitmentHarness is BLSAggregator {
    constructor(address r, address sp, address dvt) BLSAggregator(r, sp, dvt) {}
    function exposeCommitment(bytes calldata proof, uint256 pid, bytes32 mh)
        external view returns (bytes32)
    {
        return _computeSignersCommitment(proof, pid, mh);
    }
}

contract StubReg { fallback() external payable {} }

/// @title  A' signer-set commitment (CC-89 stage-2) unit tests
/// @notice Verifies the on-chain commitment is canonical-ordered, reproducible by
///         an off-chain verifier, domain-separated, and binds signerMask — the
///         properties a fraud-proof verifier relies on to match claimedSigners.
///         (Full verifyAndExecute storage is exercised in Phase-2 testnet E2E with
///         real BLS proofs; this isolates the encoding/order logic.)
contract SignersCommitmentTest is Test {
    using stdStorage for StdStorage;

    CommitmentHarness h;

    function setUp() public {
        h = new CommitmentHarness(address(new StubReg()), address(0x5050), address(0xD57));
    }

    function _setSlot(uint8 slot, address v) internal {
        stdstore.target(address(h)).sig("validatorAtSlot(uint8)").with_key(uint256(slot)).checked_write(v);
    }

    function _expected(uint256 mask, uint256 pid, bytes32 mh, address[] memory sorted)
        internal view returns (bytes32)
    {
        return keccak256(abi.encode(
            h.domainSeparator(), h.TAG_SIGNERS_COMMITMENT(), pid, mh, mask, sorted
        ));
    }

    // Signers collected in slot order must be re-ordered ascending by address, and
    // an off-chain party using the same encoding reproduces the identical hash.
    function test_SortsAscending_AndReproducible() public {
        address a = address(0x00A0); // uint160 160  (lower)
        address b = address(0xF0F0); // uint160 61680 (higher)
        _setSlot(1, b); // slot 1 holds the HIGHER address
        _setSlot(3, a); // slot 3 holds the LOWER address
        uint256 mask = (uint256(1) << 0) | (uint256(1) << 2); // slots 1,3
        bytes memory proof = abi.encode(mask, bytes(""));

        bytes32 got = h.exposeCommitment(proof, 42, bytes32(uint256(0xABC)));

        address[] memory sorted = new address[](2);
        sorted[0] = a; // ascending
        sorted[1] = b;
        assertEq(got, _expected(mask, 42, bytes32(uint256(0xABC)), sorted), "ascending + reproducible");
    }

    function test_DomainSeparation_ProposalId() public {
        _setSlot(1, address(0x00A0));
        bytes memory proof = abi.encode(uint256(1), bytes(""));
        assertTrue(
            h.exposeCommitment(proof, 1, bytes32(0)) != h.exposeCommitment(proof, 2, bytes32(0)),
            "different proposalId -> different commitment"
        );
    }

    function test_DomainSeparation_MessageHash() public {
        _setSlot(1, address(0x00A0));
        bytes memory proof = abi.encode(uint256(1), bytes(""));
        assertTrue(
            h.exposeCommitment(proof, 1, bytes32(uint256(1))) != h.exposeCommitment(proof, 1, bytes32(uint256(2))),
            "different messageHash -> different commitment"
        );
    }

    // Same address set but a different signerMask (different slot layout) must yield
    // a different commitment — signerMask is bound into the encoding.
    function test_SignerMaskBound() public {
        _setSlot(1, address(0x00A0));
        _setSlot(2, address(0x00A0));
        bytes32 c1 = h.exposeCommitment(abi.encode(uint256(1) << 0, bytes("")), 1, bytes32(0));
        bytes32 c2 = h.exposeCommitment(abi.encode(uint256(1) << 1, bytes("")), 1, bytes32(0));
        assertTrue(c1 != c2, "signerMask bound");
    }

    // A single-signer commitment is well-formed and reproducible.
    function test_SingleSigner() public {
        address a = address(0xBEEF);
        _setSlot(5, a);
        uint256 mask = uint256(1) << 4; // slot 5
        bytes memory proof = abi.encode(mask, bytes(""));
        address[] memory sorted = new address[](1);
        sorted[0] = a;
        assertEq(h.exposeCommitment(proof, 7, bytes32(uint256(9))), _expected(mask, 7, bytes32(uint256(9)), sorted));
    }
}
