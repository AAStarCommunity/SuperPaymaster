// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice Deployment-fixed predicate for one DVT raw-evidence category.
interface IEvidenceCategory {
    function check(address operator, uint8 level, uint256 epoch, bytes calldata body) external view returns (bool);
}
