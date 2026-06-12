// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "src/interfaces/v3/IRegistry.sol";

/**
 * @title InvariantMocks
 * @notice Minimal mocks shared by the invariant test suite. Kept deliberately
 *         tiny — invariant runs are deep, so the harness must be cheap.
 */

contract InvMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) {
        return keccak256(abi.encode(op, block.chainid));
    }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract InvMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract InvMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @notice Registry mock exposing only the surface SuperPaymaster reads in the
 *         funding paths: role checks. Everything else is a no-op stub.
 */
contract InvMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function setRole(bytes32 role, address user, bool v) external {
        roles[role][user] = v;
    }
    function hasRole(bytes32 role, address user) external view returns (bool) {
        return roles[role][user];
    }

    // ── view stubs ──────────────────────────────────────────────────────────
    function version() external pure returns (string memory) { return "InvMock"; }
    function getCreditLimit(address) external pure returns (uint256) { return 0; }
    function isReputationSource(address) external pure returns (bool) { return false; }
    function getEffectiveStake(address, bytes32) external pure returns (uint256) { return 0; }
    function getRoleConfig(bytes32) external pure returns (IRegistry.RoleConfig memory r) { return r; }
    function getUserRoles(address) external pure returns (bytes32[] memory r) { return r; }
    function getRoleUserCount(bytes32) external pure returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external pure returns (uint256) { return 0; }

    // ── no-op mutators ────────────────────────────────────────────────────────
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setCreditTier(uint256, uint256) external {}
    function syncStakeFromStaking(address, bytes32, uint256) external {}
}
