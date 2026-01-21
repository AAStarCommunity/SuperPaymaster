// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
interface IBLSAggregator {
    function threshold() external view returns (uint256);
    
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
}