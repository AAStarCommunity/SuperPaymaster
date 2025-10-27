// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title GasTokenV2
 * @notice ERC20 token with updatable auto-approval for Paymaster contract
 * @dev Enhanced version that supports changing the approved paymaster
 *
 * Key improvements from V1:
 * - Settlement/Paymaster address is now updatable (not immutable)
 * - Owner can switch to different Paymaster contracts
 * - Maintains auto-approval functionality
 * - Backward compatible with V3 Settlement or V4 Paymaster
 */
contract GasTokenV2 is ERC20, Ownable {
    /// @notice Paymaster/Settlement contract address (updatable)
    address public paymaster;

    /// @notice Exchange rate relative to base PNT (1e18 = 1:1)
    /// @dev Example: 1.2e18 means 1 token = 1.2 base PNT
    uint256 public exchangeRate;

    /// @notice Token price in USD (18 decimals), e.g., 0.02e18 = $0.02
    /// @dev Used by Paymaster to calculate gas cost in tokens
    uint256 public priceUSD;

    /// @notice Maximum approval amount (effectively unlimited)
    uint256 private constant MAX_APPROVAL = type(uint256).max;

    /// @notice Event emitted when paymaster is updated
    event PaymasterUpdated(address indexed oldPaymaster, address indexed newPaymaster);

    /// @notice Event emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Event emitted when price is updated
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice Event emitted when token is auto-approved
    event AutoApproved(address indexed user, address indexed paymaster, uint256 amount);

    /// @notice Error when setting zero address as paymaster
    error ZeroPaymaster();

    /// @notice Error when setting zero exchange rate
    error ZeroExchangeRate();

    /// @notice Error when user tries to revoke paymaster approval
    error CannotRevokePaymasterApproval();

    /**
     * @notice Create a new GasTokenV2
     * @param name Token name (e.g., "Points Token")
     * @param symbol Token symbol (e.g., "PNT")
     * @param _paymaster Initial Paymaster/Settlement contract address
     * @param _exchangeRate Initial exchange rate (1e18 = 1:1)
     * @param _priceUSD Initial price in USD (18 decimals), default 0.02e18 = $0.02
     */
    constructor(
        string memory name,
        string memory symbol,
        address _paymaster,
        uint256 _exchangeRate,
        uint256 _priceUSD
    ) ERC20(name, symbol) Ownable(msg.sender) {
        if (_paymaster == address(0)) revert ZeroPaymaster();
        if (_exchangeRate == 0) revert ZeroExchangeRate();

        paymaster = _paymaster;
        exchangeRate = _exchangeRate;
        priceUSD = _priceUSD > 0 ? _priceUSD : 0.02e18; // Default to $0.02 if not specified
    }

    /**
     * @notice Update paymaster contract (only owner)
     * @param _newPaymaster New Paymaster/Settlement contract address
     * @dev When paymaster changes, all existing holders need re-approval
     *      This will happen automatically on their next transfer
     */
    function setPaymaster(address _newPaymaster) external onlyOwner {
        if (_newPaymaster == address(0)) revert ZeroPaymaster();

        address oldPaymaster = paymaster;
        paymaster = _newPaymaster;

        emit PaymasterUpdated(oldPaymaster, _newPaymaster);
    }

    /**
     * @notice Mint tokens to an address with auto-approval
     * @param to Recipient address
     * @param amount Amount to mint (18 decimals)
     * @dev Automatically approves current Paymaster contract
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);

        // Auto-approve current Paymaster contract
        _approve(to, paymaster, MAX_APPROVAL);

        emit AutoApproved(to, paymaster, MAX_APPROVAL);
    }

    /**
     * @notice Override _update to ensure Paymaster approval on transfers
     * @dev Maintains permanent approval even after transfers or paymaster changes
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);

        // If tokens are being transferred TO someone (not burn)
        // And they don't have max approval yet, auto-approve
        if (to != address(0) && allowance(to, paymaster) < MAX_APPROVAL) {
            _approve(to, paymaster, MAX_APPROVAL);
            emit AutoApproved(to, paymaster, MAX_APPROVAL);
        }
    }

    /**
     * @notice Update exchange rate (only owner)
     * @param _exchangeRate New exchange rate
     */
    function setExchangeRate(uint256 _exchangeRate) external onlyOwner {
        if (_exchangeRate == 0) revert ZeroExchangeRate();

        uint256 oldRate = exchangeRate;
        exchangeRate = _exchangeRate;

        emit ExchangeRateUpdated(oldRate, _exchangeRate);
    }

    /**
     * @notice Update token price in USD (only owner)
     * @param _priceUSD New price in USD (18 decimals)
     */
    function setPrice(uint256 _priceUSD) external onlyOwner {
        if (_priceUSD == 0) revert ZeroExchangeRate(); // Reuse error for simplicity

        uint256 oldPrice = priceUSD;
        priceUSD = _priceUSD;

        emit PriceUpdated(oldPrice, _priceUSD);
    }

    /**
     * @notice Get token price in USD
     * @return Token price in USD (18 decimals)
     */
    function getPrice() external view returns (uint256) {
        return priceUSD;
    }

    /**
     * @notice Override approve to prevent users from revoking Paymaster approval
     * @dev Users can approve other addresses, but cannot reduce Paymaster approval
     */
    function approve(address spender, uint256 value) public override returns (bool) {
        // If trying to approve Paymaster contract
        if (spender == paymaster) {
            // Can only increase approval, not decrease
            if (value < allowance(msg.sender, paymaster)) {
                revert CannotRevokePaymasterApproval();
            }
        }

        return super.approve(spender, value);
    }

    /**
     * @notice Get token information
     * @return _paymaster Current Paymaster contract address
     * @return _exchangeRate Exchange rate
     * @return _totalSupply Total token supply
     */
    function getInfo() external view returns (
        address _paymaster,
        uint256 _exchangeRate,
        uint256 _totalSupply
    ) {
        return (paymaster, exchangeRate, totalSupply());
    }

    /**
     * @notice Batch re-approve for existing holders after paymaster change
     * @param holders Array of holder addresses to re-approve
     * @dev Helper function for owner to update approvals after changing paymaster
     *      Can also be triggered automatically via transfers
     */
    function batchReapprove(address[] calldata holders) external onlyOwner {
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (balanceOf(holder) > 0 && allowance(holder, paymaster) < MAX_APPROVAL) {
                _approve(holder, paymaster, MAX_APPROVAL);
                emit AutoApproved(holder, paymaster, MAX_APPROVAL);
            }
        }
    }
}
