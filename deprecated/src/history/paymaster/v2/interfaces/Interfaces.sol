// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Interfaces
 * @notice Shared interfaces for SuperPaymaster v2.0 system
 */

// ====================================
// ERC-4337 Structures (EntryPoint v0.7)
// ====================================

/**
 * User Operation struct
 * @param sender                - The sender account of this request.
 * @param nonce                 - Unique value the sender uses to verify it is not a replay.
 * @param initCode              - If set, the account contract will be created by this constructor
 * @param callData              - The method call to execute on this account.
 * @param accountGasLimits      - Packed gas limits for validateUserOp and gas limit passed to the callData method call.
 * @param preVerificationGas    - Gas not calculated by the handleOps method, but added to the gas paid.
 * @param gasFees               - packed gas fields maxPriorityFeePerGas and maxFeePerGas - Same as EIP-1559 gas parameters.
 * @param paymasterAndData      - If set, this field holds the paymaster address, verification gas limit, postOp gas limit and paymaster-specific extra data
 * @param signature             - Sender-verified signature over the entire request, the EntryPoint address and the chain ID.
 */
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

// ====================================
// ERC-4337 IEntryPoint Interface (EntryPoint v0.7)
// ====================================

/**
 * @title IEntryPoint
 * @notice Minimal EntryPoint interface for paymaster operations
 */
interface IEntryPoint {
    /**
     * @notice Deposit ETH for a given account
     * @param account Account to credit
     */
    function depositTo(address account) external payable;

    /**
     * @notice Withdraw ETH for caller
     * @param withdrawAddress Address to send withdrawn ETH
     * @param withdrawAmount Amount to withdraw
     */
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;

    /**
     * @notice Add stake for caller
     * @param unstakeDelaySec Delay before stake can be unlocked (seconds)
     */
    function addStake(uint32 unstakeDelaySec) external payable;

    /**
     * @notice Unlock stake (must wait unstakeDelay before withdrawing)
     */
    function unlockStake() external;

    /**
     * @notice Withdraw stake
     * @param withdrawAddress Address to send withdrawn stake
     */
    function withdrawStake(address payable withdrawAddress) external;

    /**
     * @notice Get deposit balance for account
     * @param account Account to check
     * @return Deposit balance
     */
    function balanceOf(address account) external view returns (uint256);
}

// ====================================
// ERC-4337 IPaymaster Interface (EntryPoint v0.7)
// ====================================

/**
 * @title IPaymaster
 * @notice Standard paymaster interface for EntryPoint v0.7
 */
interface IPaymaster {
    enum PostOpMode {
        opSucceeded,
        opReverted,
        postOpReverted
    }

    /**
     * @notice Payment validation: check if paymaster agrees to pay (must be called by EntryPoint)
     * @param userOp The user operation
     * @param userOpHash Hash of the user's request data
     * @param maxCost Maximum cost of this transaction (based on maximum gas and gas price from userOp)
     * @return context Value to send to postOp (empty for modes that don't use postOp)
     * @return validationData Signature and time-range of this operation (0 for valid, 1 for invalid)
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    /**
     * @notice Post-operation handler (must be called by EntryPoint)
     * @param mode Enum with the following options: opSucceeded, opReverted, postOpReverted
     * @param context Value returned by validatePaymasterUserOp
     * @param actualGasCost Actual gas used so far (without this postOp call)
     * @param actualUserOpFeePerGas The gas price this UserOp pays
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external;
}

// ====================================
// GToken Staking Interface
// ====================================

interface IGTokenStaking {
    function lockStake(address user, uint256 amount, string memory purpose) external;
    function unlockStake(address user, uint256 grossAmount) external returns (uint256 netAmount);
    function slash(address operator, uint256 amount, string memory reason) external returns (uint256 slashedAmount);
    function stake(uint256 amount) external returns (uint256 shares);
    function stakeFor(address beneficiary, uint256 amount) external returns (uint256 shares);
    function balanceOf(address user) external view returns (uint256);
    function availableBalance(address user) external view returns (uint256);
    function previewExitFee(address user, address locker) external view returns (uint256 fee, uint256 netAmount);
    function getLockedStake(address user, address locker) external view returns (uint256);
}

// ====================================
// GToken Interface
// ====================================

interface IGToken {
    function burn(uint256 amount) external;
}

// ====================================
// xPNTs Token Interface
// ====================================

interface IxPNTsToken {
    function burn(address from, uint256 amount) external;
}

// ====================================
// SuperPaymaster Interface
// ====================================

interface ISuperPaymaster {
    enum SlashLevel {
        WARNING,
        MINOR,
        MAJOR
    }

    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof
    ) external;

    // ====================================
    // V2.3.3: SBT Registry Callbacks
    // ====================================

    /**
     * @notice Register SBT holder (V2.3.3 - called by MySBT on mint)
     * @param holder SBT owner address
     * @param tokenId MySBT token ID
     */
    function registerSBTHolder(address holder, uint256 tokenId) external;

    /**
     * @notice Remove SBT holder (V2.3.3 - called by MySBT on burn)
     * @param holder SBT owner address
     */
    function removeSBTHolder(address holder) external;
}

// ====================================
// DVT Validator Interface
// ====================================

interface IDVTValidator {
    function markProposalExecuted(uint256 proposalId) external;
}

// ====================================
// BLS Aggregator Interface
// ====================================

interface IBLSAggregator {
    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] memory validators,
        bytes[] memory signatures
    ) external;
}

// ====================================
// Registry v2.1 Interface
// ====================================

interface IRegistryV2_1 {
    /**
     * @notice Check if a community is registered
     * @param community Community address to check
     * @return True if community is registered
     */
    function isRegisteredCommunity(address community) external view returns (bool);

    /**
     * @notice Check if a community allows permissionless MySBT minting
     * @param communityAddress Community address to check
     * @return allowed True if users can mint without invitation
     */
    function isPermissionlessMintAllowed(address communityAddress)
        external
        view
        returns (bool allowed);
}
