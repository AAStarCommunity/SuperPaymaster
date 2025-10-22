// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title xPNTsToken
 * @notice Community points token with pre-authorization mechanism
 * @dev ERC20 + EIP-2612 Permit + Auto-approval for trusted contracts
 *
 * Key Features:
 * - Override allowance() to return type(uint256).max for trusted spenders
 * - No need for users to approve() before using xPNTs
 * - EIP-2612 Permit for gasless approvals
 * - 1:1 conversion to aPNTs (Account Abstraction PNTs)
 *
 * Pre-Authorization:
 * - SuperPaymaster v2.0 (for depositing aPNTs)
 * - xPNTsFactory (for management)
 * - MySBT (for mint fees)
 *
 * Example Usage:
 * 1. User receives xPNTs from community
 * 2. User calls SuperPaymaster.depositAPNTs(100 ether)
 * 3. SuperPaymaster.burn() is called automatically (no approve needed!)
 * 4. User's aPNTs balance increases by 100
 */
contract xPNTsToken is ERC20, ERC20Permit {

    // ====================================
    // Storage
    // ====================================

    /// @notice Factory contract that deployed this token
    address public immutable FACTORY;

    /// @notice Community owner/admin address
    address public communityOwner;

    /// @notice Pre-authorized spenders (no approve needed)
    mapping(address => bool) public autoApprovedSpenders;

    /// @notice Community name
    string public communityName;

    /// @notice Community ENS domain
    string public communityENS;

    // ====================================
    // Events
    // ====================================

    event AutoApprovedSpenderAdded(address indexed spender);
    event AutoApprovedSpenderRemoved(address indexed spender);
    event CommunityOwnerUpdated(address indexed oldOwner, address indexed newOwner);

    // ====================================
    // Errors
    // ====================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Deploy new xPNTs token
     * @param name Token name (e.g., "MyDAO Points")
     * @param symbol Token symbol (e.g., "xMDAO")
     * @param _communityOwner Community admin address
     * @param _communityName Community display name
     * @param _communityENS Community ENS domain
     */
    constructor(
        string memory name,
        string memory symbol,
        address _communityOwner,
        string memory _communityName,
        string memory _communityENS
    ) ERC20(name, symbol) ERC20Permit(name) {
        if (_communityOwner == address(0)) {
            revert InvalidAddress(_communityOwner);
        }

        FACTORY = msg.sender;
        communityOwner = _communityOwner;
        communityName = _communityName;
        communityENS = _communityENS;
    }

    // ====================================
    // Pre-Authorization Mechanism
    // ====================================

    /**
     * @notice Override allowance() to implement pre-authorization
     * @param owner Token owner
     * @param spender Spender address
     * @return Current allowance (type(uint256).max if pre-authorized)
     * @dev This is the core of the pre-authorization mechanism!
     *      Trusted contracts get infinite allowance without user approval
     */
    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        // If spender is pre-authorized, return max allowance
        if (autoApprovedSpenders[spender]) {
            return type(uint256).max;
        }

        // Otherwise return normal allowance
        return super.allowance(owner, spender);
    }

    /**
     * @notice Add trusted spender to pre-authorization list
     * @param spender Contract address to trust
     * @dev Only community owner or factory can add trusted spenders
     */
    function addAutoApprovedSpender(address spender) external {
        if (msg.sender != communityOwner && msg.sender != FACTORY) {
            revert Unauthorized(msg.sender);
        }
        if (spender == address(0)) {
            revert InvalidAddress(spender);
        }

        autoApprovedSpenders[spender] = true;
        emit AutoApprovedSpenderAdded(spender);
    }

    /**
     * @notice Remove spender from pre-authorization list
     * @param spender Contract address to remove
     */
    function removeAutoApprovedSpender(address spender) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }

        autoApprovedSpenders[spender] = false;
        emit AutoApprovedSpenderRemoved(spender);
    }

    /**
     * @notice Check if spender is pre-authorized
     * @param spender Address to check
     * @return isApproved True if pre-authorized
     */
    function isAutoApproved(address spender) external view returns (bool isApproved) {
        return autoApprovedSpenders[spender];
    }

    // ====================================
    // Minting & Burning
    // ====================================

    /**
     * @notice Mint xPNTs (only Factory or Owner)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != FACTORY && msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (to == address(0)) {
            revert InvalidAddress(to);
        }

        _mint(to, amount);
    }

    /**
     * @notice Burn xPNTs (for converting to aPNTs)
     * @param from Address to burn from
     * @param amount Amount to burn
     * @dev Automatically checks allowance (pre-auth returns max)
     */
    function burn(address from, uint256 amount) external {
        // If caller is not the owner, check allowance
        if (msg.sender != from) {
            uint256 allowed = allowance(from, msg.sender);

            if (allowed < amount) {
                revert("Insufficient allowance");
            }

            // If not infinite allowance, decrease it
            if (allowed != type(uint256).max) {
                _approve(from, msg.sender, allowed - amount);
            }
        }

        _burn(from, amount);
    }

    /**
     * @notice Burn xPNTs from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Transfer community ownership
     * @param newOwner New owner address
     */
    function transferCommunityOwnership(address newOwner) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (newOwner == address(0)) {
            revert InvalidAddress(newOwner);
        }

        address oldOwner = communityOwner;
        communityOwner = newOwner;

        emit CommunityOwnerUpdated(oldOwner, newOwner);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get token metadata
     * @return _name Token name
     * @return _symbol Token symbol
     * @return _communityName Community name
     * @return _communityENS Community ENS
     * @return _communityOwner Community owner
     */
    function getMetadata()
        external
        view
        returns (
            string memory _name,
            string memory _symbol,
            string memory _communityName,
            string memory _communityENS,
            address _communityOwner
        )
    {
        return (
            name(),
            symbol(),
            communityName,
            communityENS,
            communityOwner
        );
    }

    /**
     * @notice Check if address needs approval
     * @param owner Token owner
     * @param spender Spender address
     * @param amount Amount to spend
     * @return needsApproval True if approve() call is needed
     */
    function needsApproval(address owner, address spender, uint256 amount)
        external
        view
        returns (bool)
    {
        uint256 currentAllowance = allowance(owner, spender);
        return currentAllowance < amount;
    }
}
