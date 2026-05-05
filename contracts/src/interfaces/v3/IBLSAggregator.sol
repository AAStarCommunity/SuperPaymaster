// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

interface IBLSAggregator {
    function minThreshold() external view returns (uint256);
    function defaultThreshold() external view returns (uint256);

    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] calldata repUsers,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external;

    function setDVTValidator(address _dvt) external;

    /// @notice External BLS verification entry point (P0-1).
    /// @dev    Both pkAgg and msgG2 are reconstructed on-chain — callers cannot
    ///         supply them. Returns true iff the BLS12-381 pairing check passes
    ///         and the selected validator set meets `requiredThreshold`.
    function verify(
        bytes32 expectedMessageHash,
        uint256 signerMask,
        uint256 requiredThreshold,
        bytes calldata sigBytes
    ) external view returns (bool);
}
