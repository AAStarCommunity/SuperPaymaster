// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../interfaces/IERC1363.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";


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
contract xPNTsToken is ERC20, ERC20Permit, IVersioned {

    // ====================================
    // Storage
    // ====================================

    /// @notice Factory contract that deployed this token
    address public immutable FACTORY;

    /// @notice Community owner/admin address
    address public communityOwner;

    /// @notice The address of the trusted SuperPaymaster, which can call special functions.
    address public SUPERPAYMASTER_ADDRESS;

    /// @notice Pre-authorized spenders (no approve needed)
    mapping(address => bool) public autoApprovedSpenders;

    /// @notice Ensures a UserOperation hash is only used once for payment.
    mapping(bytes32 => bool) public usedOpHashes;

    /// @notice Community name
    string public communityName;

    /// @notice Community ENS domain
    string public communityENS;

    /// @notice Exchange rate with aPNTs (18 decimals, 1e18 = 1:1)
    /// @dev xPNTs amount = aPNTs amount * exchangeRate / 1e18
    uint256 public exchangeRate;

    /// @notice User debt balance in xPNTs
    mapping(address => uint256) public debts;

    /// @notice User spending limits for specific spenders (e.g., Paymaster)
    /// @dev user => spender => maxCumulativeDebt
    mapping(address => mapping(address => uint256)) public spendingLimits;

    /// @notice User cumulative spent per spender
    /// @dev user => spender => currentCumulativeSpent
    mapping(address => mapping(address => uint256)) public cumulativeSpent;
    function version() external pure override returns (string memory) {
        return "XPNTs-2.2.2-credit";
    }

    // ====================================
    // Events
    // ====================================

    event AutoApprovedSpenderAdded(address indexed spender);
    event AutoApprovedSpenderRemoved(address indexed spender);
    event CommunityOwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
    event SuperPaymasterAddressUpdated(address indexed newSuperPaymaster);
    event DebtRecorded(address indexed user, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt);
    event SpendingLimitUpdated(address indexed user, address indexed spender, uint256 newLimit);


    // ====================================
    // Errors
    // ====================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);
    error OperationAlreadyProcessed(bytes32 userOpHash);

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
     * @param _exchangeRate Exchange rate with aPNTs (18 decimals, 0 = default 1:1)
     */
    // ====================================
    // IERC1363 Support (Push-based transfers)
    // ====================================

    /**
     * @notice Transfer tokens to a contract and call onTransferReceived
     */
    function transferAndCall(address to, uint256 amount) external returns (bool) {
        return transferAndCall(to, amount, "");
    }

    /**
     * @notice Transfer tokens to a contract and call onTransferReceived with data
     */
    function transferAndCall(address to, uint256 amount, bytes memory data) public returns (bool) {
        transfer(to, amount);
        require(_checkOnTransferReceived(msg.sender, to, amount, data), "ERC1363: transfer to non-receiver");
        return true;
    }

    /**
     * @dev Internal function to invoke onTransferReceived on a target address.
     */
    function _checkOnTransferReceived(address from, address to, uint256 amount, bytes memory data) internal returns (bool) {
        if (to.code.length == 0) return true;
        try IERC1363Receiver(to).onTransferReceived(msg.sender, from, amount, data) returns (bytes4 retval) {
            return retval == IERC1363Receiver.onTransferReceived.selector;
        } catch {
            return false;
        }
    }

    constructor(
        string memory name,
        string memory symbol,
        address _communityOwner,
        string memory _communityName,
        string memory _communityENS,
        uint256 _exchangeRate
    ) ERC20(name, symbol) ERC20Permit(name) {
        if (_communityOwner == address(0)) {
            revert InvalidAddress(_communityOwner);
        }

        FACTORY = msg.sender;
        communityOwner = _communityOwner;
        communityName = _communityName;
        communityENS = _communityENS;

        // Set exchange rate (default 1:1 if not specified)
        exchangeRate = _exchangeRate > 0 ? _exchangeRate : 1 ether;
    }

    // ====================================
    // Pre-Authorization & Security Mechanism
    // ====================================

    /**
     * @notice Override allowance() to implement pre-authorization
     * @dev For UI and compatibility, we still show max allowance for auto-approved spenders.
     *      However, the actual transfer is firewalled by the _spendAllowance override.
     */
    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        if (autoApprovedSpenders[spender]) {
            uint256 limit = spendingLimits[owner][spender];
            uint256 spent = cumulativeSpent[owner][spender];
            return limit > spent ? limit - spent : 0;
        }
        return super.allowance(owner, spender);
    }

    /**
     * @dev FIREWALL: Overrides the internal allowance spending mechanism.
     * This is the core security feature that prevents the SuperPaymaster from using
     * its infinite allowance with standard `transferFrom`.
     */
    /**
     * @notice Secure TransferFrom for SuperPaymaster
     * @dev Restricts SuperPaymaster to ONLY transfer tokens to itself (Deposit).
     *      Prevents the Paymaster from draining user funds to arbitrary addresses.
     */
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        if (msg.sender == SUPERPAYMASTER_ADDRESS) {
            if (to != SUPERPAYMASTER_ADDRESS) {
                 revert("SuperPaymaster Security: Can only pull funds to self");
            }
        }
        return super.transferFrom(from, to, value);
    }

    /**
     * @dev FIREWALL: Overrides the internal allowance spending mechanism.
     * This is the core security feature that prevents the SuperPaymaster from using
     * its infinite allowance with standard `transferFrom`.
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual override {
        // Validation moved to transferFrom to support DepositFor
        super._spendAllowance(owner, spender, amount);
    }

    /**
     * @notice The ONLY function the SuperPaymaster can call to deduct funds.
     * @param from The user's address to burn tokens from.
     * @param amount The amount of tokens to burn.
     * @param userOpHash The unique hash of the UserOperation, preventing replays.
     */
    function burnFromWithOpHash(address from, uint256 amount, bytes32 userOpHash) external {
        // 1. Identity Check: Only the registered SuperPaymaster can call this.
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        
        // 2. Replay Protection: Ensure this UserOp hasn't been processed.
        if (usedOpHashes[userOpHash]) {
            revert OperationAlreadyProcessed(userOpHash);
        }

        // 3. Mark Hash as used
        usedOpHashes[userOpHash] = true;

        // 4. Enforce Spending Limit (Mandatory V3.6)
        uint256 limit = spendingLimits[from][msg.sender];
        uint256 newTotalSpent = cumulativeSpent[from][msg.sender] + amount;
        if (newTotalSpent > limit) revert("Spending limit exceeded");
        cumulativeSpent[from][msg.sender] = newTotalSpent;

        // 5. Execute Burn
        _burn(from, amount);
    }


    
    // ====================================
    // Debt Management (V3.2)
    // ====================================

    /**
     * @notice Record user debt (only SuperPaymaster)
     */
    function recordDebt(address user, uint256 amountXPNTs) external {
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }

        // V3.6 SECURITY: Enforce Spending Limits
        uint256 limit = spendingLimits[user][msg.sender];
        uint256 newTotalSpent = cumulativeSpent[user][msg.sender] + amountXPNTs;
        if (newTotalSpent > limit) revert("Spending limit exceeded");
        cumulativeSpent[user][msg.sender] = newTotalSpent;

        debts[user] += amountXPNTs;
        emit DebtRecorded(user, amountXPNTs);
    }

    /**
     * @notice Set spending limit for a specific spender (e.g., Paymaster)
     */
    function setPaymasterLimit(address spender, uint256 limit) external {
        spendingLimits[msg.sender][spender] = limit;
        emit SpendingLimitUpdated(msg.sender, spender, limit);
    }
    
    /**
     * @notice Manually repay debt using user's xPNTs balance
     */
    function repayDebt(uint256 amount) external {
        uint256 debt = debts[msg.sender];
        if (debt == 0) return;
        uint256 repayAmount = amount > debt ? debt : amount;
        _burn(msg.sender, repayAmount);
        debts[msg.sender] -= repayAmount;
        emit DebtRepaid(msg.sender, repayAmount, debts[msg.sender]);
    }
    
    function getDebt(address user) external view returns (uint256) {
        return debts[user];
    }
    
    /**
     * @notice Override _update to implement Auto-Repayment
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Feature: Auto-Repayment ONLY on MINT (Income from Community/Protocol)
        // This preserves ERC20 standard behavior for regular user-to-user transfers.
        if (from == address(0) && to != address(0) && value > 0) {
            uint256 debt = debts[to];
            if (debt > 0) {
                // Auto-Repay Logic
                uint256 repayAmount = value > debt ? debt : value;
                
                // 1. Reduce Debt
                debts[to] -= repayAmount;
                
                // 2. Process Mint (Full amount first for standard event emitting)
                super._update(from, to, value); 
                
                // 3. Immediately burn the repaid amount from 'to'
                if (repayAmount > 0) {
                    _burn(to, repayAmount);
                    emit DebtRepaid(to, repayAmount, debts[to]);
                }
                return;
            }
        }
        
        super._update(from, to, value);
    }

    /**
     * @notice Sets or updates the trusted SuperPaymaster address.
     * @dev Can only be called by the factory or the community owner.
     */
    function setSuperPaymasterAddress(address _spAddress) external {
        if (msg.sender != FACTORY && msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (_spAddress == address(0)) {
            revert InvalidAddress(_spAddress);
        }
        SUPERPAYMASTER_ADDRESS = _spAddress;
        emit SuperPaymasterAddressUpdated(_spAddress);
    }

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

    function removeAutoApprovedSpender(address spender) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }

        autoApprovedSpenders[spender] = false;
        emit AutoApprovedSpenderRemoved(spender);
    }

    // ====================================
    // Minting & Standard Burning
    // ====================================

    function mint(address to, uint256 amount) external {
        if (msg.sender != FACTORY && msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (to == address(0)) {
            revert InvalidAddress(to);
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        // SECURITY: The SuperPaymaster is explicitly forbidden from using this function.
        if (msg.sender == SUPERPAYMASTER_ADDRESS) {
            revert("SuperPaymaster must use burnFromWithOpHash()");
        }

        if (msg.sender != from) {
            uint256 allowed = allowance(from, msg.sender);
            if (allowed < amount) {
                revert("ERC20: burn amount exceeds allowance");
            }
            if (allowed != type(uint256).max) {
                _approve(from, msg.sender, allowed - amount);
            }
        }
        _burn(from, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ... (rest of the original functions: updateExchangeRate, transferCommunityOwnership, getMetadata, etc.) ...
    
    function updateExchangeRate(uint256 newRate) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        require(newRate > 0, "Rate must be positive");

        uint256 oldRate = exchangeRate;
        exchangeRate = newRate;

        emit ExchangeRateUpdated(oldRate, newRate);
    }

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

    function needsApproval(address owner, address spender, uint256 amount)
        external
        view
        returns (bool)
    {
        uint256 currentAllowance = allowance(owner, spender);
        return currentAllowance < amount;
    }
}