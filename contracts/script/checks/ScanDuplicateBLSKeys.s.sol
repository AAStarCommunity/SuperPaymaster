// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import {BLS} from "src/utils/BLS.sol";

interface IAggregatorKeyScan {
    function MAX_VALIDATORS() external view returns (uint256);
    function validatorAtSlot(uint8 slot) external view returns (address);
    function getBLSPublicKey(address validator)
        external
        view
        returns (BLS.G1Point memory publicKey, uint8 slot, bool isActive);
    function version() external view returns (string memory);
}

/**
 * @title ScanDuplicateBLSKeys
 * @notice CC-48 round-2: audit an ALREADY-DEPLOYED BLSAggregator for the condition
 *         `blsKeyOwner` now prevents — the same G1 public key bound to more than one
 *         validator address.
 *
 * Why this exists as a script and not only as a contract check: BLSAggregator is not
 * upgradeable, so contracts deployed before 4.6.0 keep whatever key table they
 * accumulated. The on-chain guard protects new registrations on new deployments; it
 * cannot retroactively inspect an old one. Migration therefore has two halves —
 * deploy 4.6.0 fresh (which starts with an empty, guarded table) and run this against
 * the OLD contract to learn whether any validator must be excluded from re-onboarding.
 *
 * A duplicate is not a cosmetic finding. N slots holding one key make the
 * reconstructed pkAgg equal N*pk, and the single holder of sk can produce N*sk*H(m) —
 * a valid aggregate signature for an N-signer mask, held by one party. Any deployment
 * that reports duplicates must be treated as having had an effective quorum of
 * (distinct keys), not (slots).
 *
 * Also flags a key whose scalar is trivially guessable (the public 1..32 test
 * scalars), because that is the exact state the RepCredit experiment stack was found
 * in and it is indistinguishable from a legitimate key by shape alone.
 *
 * Usage:
 *   BLS_AGGREGATOR=0x... forge script contracts/script/checks/ScanDuplicateBLSKeys.s.sol \
 *     --rpc-url $RPC_URL
 *
 * Exit behaviour: reverts if a duplicate or a known-weak key is found, so it can gate
 * a deployment pipeline instead of only printing.
 */
contract ScanDuplicateBLSKeys is Script {
    uint256 internal constant WEAK_SCALAR_SCAN_LIMIT = 32;

    function run() external view {
        address aggregator = vm.envAddress("BLS_AGGREGATOR");
        IAggregatorKeyScan agg = IAggregatorKeyScan(aggregator);

        console.log("aggregator :", aggregator);
        console.log("version    :", agg.version());

        uint256 maxValidators = agg.MAX_VALIDATORS();
        bytes32[] memory keyHashes = new bytes32[](maxValidators + 1);
        address[] memory owners = new address[](maxValidators + 1);
        uint256 populated;
        uint256 duplicates;
        uint256 weakKeys;

        for (uint8 slot = 1; slot <= uint8(maxValidators); slot++) {
            address validator = agg.validatorAtSlot(slot);
            if (validator == address(0)) continue;

            (BLS.G1Point memory pk, , bool isActive) = agg.getBLSPublicKey(validator);
            if (!isActive) continue;

            bytes32 keyHash = keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b));
            console.log("slot", slot, "->", validator);
            console.logBytes32(keyHash);

            for (uint256 i = 0; i < populated; i++) {
                if (keyHashes[i] == keyHash) {
                    duplicates++;
                    console.log("  !! DUPLICATE of the key held by", owners[i]);
                }
            }

            if (_isWeakScalarKey(pk)) {
                weakKeys++;
                console.log("  !! WEAK KEY: derived from a small public scalar (<=", WEAK_SCALAR_SCAN_LIMIT, ")");
            }

            keyHashes[populated] = keyHash;
            owners[populated] = validator;
            populated++;
        }

        console.log("active keys      :", populated);
        console.log("duplicate keys   :", duplicates);
        console.log("weak (public) keys:", weakKeys);

        require(duplicates == 0, "CC-48: duplicate BLS public key on this aggregator; effective quorum is overstated");
        require(weakKeys == 0, "CC-48: publicly-known secret scalar in the validator set; treat as compromised");
    }

    /// @dev Recomputes g1 * s for the small scalars that appear in every BLS tutorial
    ///      and in this repo's own Prague fixtures, and compares. Cheap (<= 32 MSMs)
    ///      and catches the failure mode that actually happened.
    function _isWeakScalarKey(BLS.G1Point memory pk) internal view returns (bool) {
        for (uint256 s = 1; s <= WEAK_SCALAR_SCAN_LIMIT; s++) {
            BLS.G1Point[] memory points = new BLS.G1Point[](1);
            bytes32[] memory scalars = new bytes32[](1);
            points[0] = _g1Generator();
            scalars[0] = bytes32(s);
            BLS.G1Point memory candidate = BLS.msm(points, scalars);
            if (
                candidate.x_a == pk.x_a && candidate.x_b == pk.x_b && candidate.y_a == pk.y_a
                    && candidate.y_b == pk.y_b
            ) {
                return true;
            }
        }
        return false;
    }

    function _g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }
}
