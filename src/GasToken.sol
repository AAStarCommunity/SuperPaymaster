// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GasToken
 * @notice ERC20 token with built-in pre-approval for Settlement contract
 * @dev Used for gas fee payments in SuperPaymaster V3
 *
 * Key features:
 * - Auto-approves Settlement contract when tokens are minted
 * - Approval is permanent and cannot be revoked by users
 * - Supports exchangeRate for multi-token system
 */
contract GasToken is ERC20, Ownable {
    /// @notice Settlement contract address (immutable)
    address public immutable settlement;

    /// @notice Exchange rate relative to base PNT (1e18 = 1:1)
    /// @dev Example: 1.2e18 means 1 token = 1.2 base PNT
    uint256 public exchangeRate;

    /// @notice Maximum approval amount (effectively unlimited)
    uint256 private constant MAX_APPROVAL = type(uint256).max;

    /// @notice Event emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Event emitted when token is auto-approved
    event AutoApproved(address indexed user, uint256 amount);

    /**
     * @notice Create a new GasToken
     * @param name Token name (e.g., "Points Token")
     * @param symbol Token symbol (e.g., "PNT")
     * @param _settlement Settlement contract address
     * @param _exchangeRate Initial exchange rate (1e18 = 1:1)
     */
    constructor(
        string memory name,
        string memory symbol,
        address _settlement,
        uint256 _exchangeRate
    ) ERC20(name, symbol) Ownable(msg.sender) {
        require(_settlement != address(0), "GasToken: zero settlement");
        require(_exchangeRate > 0, "GasToken: zero rate");

        settlement = _settlement;
        exchangeRate = _exchangeRate;
    }

    /**
     * @notice Mint tokens to an address with auto-approval
     * @param to Recipient address
     * @param amount Amount to mint (18 decimals)
     * @dev Automatically approves Settlement contract
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);

        // Auto-approve Settlement contract
        _approve(to, settlement, MAX_APPROVAL);

        emit AutoApproved(to, MAX_APPROVAL);
    }

    /**
     * @notice Override _update to ensure Settlement approval on transfers
     * @dev Maintains permanent approval even after transfers
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);

        // If tokens are being transferred TO someone (not burn)
        // And they don't have max approval yet, auto-approve
        if (to != address(0) && allowance(to, settlement) < MAX_APPROVAL) {
            _approve(to, settlement, MAX_APPROVAL);
            emit AutoApproved(to, MAX_APPROVAL);
        }
    }

    /**
     * @notice Update exchange rate (only owner)
     * @param _exchangeRate New exchange rate
     */
    function setExchangeRate(uint256 _exchangeRate) external onlyOwner {
        require(_exchangeRate > 0, "GasToken: zero rate");

        uint256 oldRate = exchangeRate;
        exchangeRate = _exchangeRate;

        emit ExchangeRateUpdated(oldRate, _exchangeRate);
    }

    /**
     * @notice Override approve to prevent users from revoking Settlement approval
     * @dev Users can approve other addresses, but cannot reduce Settlement approval
     */
    function approve(address spender, uint256 value) public override returns (bool) {
        // If trying to approve Settlement contract
        if (spender == settlement) {
            // Can only increase approval, not decrease
            require(value >= allowance(msg.sender, settlement), "GasToken: cannot revoke settlement approval");
        }

        return super.approve(spender, value);
    }

    /**
     * @notice Get token information
     * @return _settlement Settlement contract address
     * @return _exchangeRate Exchange rate
     * @return _totalSupply Total token supply
     */
    function getInfo() external view returns (
        address _settlement,
        uint256 _exchangeRate,
        uint256 _totalSupply
    ) {
        return (settlement, exchangeRate, totalSupply());
    }
}
