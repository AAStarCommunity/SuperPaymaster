// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import { ERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin-v5.0.2/contracts/access/Ownable2Step.sol";
import { IERC1363Receiver } from "src/interfaces/IERC1363.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

/**
 * @title APNTsCapped
 * @notice aPNTs — the operator deposit asset of SuperPaymaster — with an ENFORCED supply cap
 *         (GOV-4 (b), docs/design/aoa-balance-mode/apnts-capped-design.md).
 * @dev    Deliberately small and NOT upgradeable, so the cap rule cannot be bypassed by an
 *         upgrade. Roles:
 *           - owner (Ownable2Step; intended: the GOV-1 48h TimelockController whose proposer /
 *             canceller is the governance multisig): raiseCap, setMinter, setCapGuardian.
 *             Raising the cap is therefore always publicly queued for 48h.
 *           - minter (governance multisig): mint, and only while totalSupply + amount <= cap.
 *           - capGuardian (governance multisig, no timelock): lowerCap — the safe direction,
 *             effective immediately. The owner may also lower.
 *         There is no factory, no auto-approved spender, no third-party burn/transfer privilege
 *         and no SuperPaymaster-specific privilege. SP only uses standard transferFrom/transfer
 *         plus the ERC-1363-style push deposit `transferAndCall` -> `onTransferReceived`.
 */
contract APNTsCapped is ERC20, ERC20Permit, Ownable2Step, IVersioned {
    /// @notice Maximum totalSupply reachable through `mint` (enforced, not advisory).
    /// @dev    Deployment values (author decisions, 2026-09-13): mainnet initial cap 300,000e18
    ///         aPNTs; Sepolia 10,000,000e18 (TEST_CAP_SEPOLIA — a test value). Set by
    ///         contracts/script/v3/DeployAPNTsCapped.s.sol; raised only through the 48h timelock.
    uint256 public cap;
    /// @notice The only address allowed to mint.
    address public minter;
    /// @notice May lower the cap immediately (the owner may too).
    address public capGuardian;

    error CapExceeded(uint256 supply, uint256 amount, uint256 cap);
    error NotMinter(address caller);
    error NotCapGuardian(address caller);
    error CapNotRaised(uint256 current, uint256 proposed);
    error CapNotLowered(uint256 current, uint256 proposed);
    error ZeroAddress();
    error ZeroCap();
    error RenounceDisabled();
    error ReceiverNotContract(address to);
    error ReceiverRejected(address to, bytes4 retval);

    event CapRaised(uint256 oldCap, uint256 newCap);
    event CapLowered(uint256 oldCap, uint256 newCap, address indexed by);
    event MinterSet(address indexed oldMinter, address indexed newMinter);
    event CapGuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event Minted(address indexed to, uint256 amount, uint256 supplyAfter, uint256 cap);

    /// @param name_        e.g. "AAStar PNTs"
    /// @param symbol_      e.g. "aPNTs"
    /// @param cap_         initial cap (> 0); initial supply is 0
    /// @param initialOwner deployer; hands over to the timelock via Ownable2Step
    /// @param minter_      the minter
    /// @param capGuardian_ the cap guardian
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        address initialOwner,
        address minter_,
        address capGuardian_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(initialOwner) {
        if (cap_ == 0) revert ZeroCap();
        if (minter_ == address(0) || capGuardian_ == address(0)) revert ZeroAddress();
        cap = cap_;
        minter = minter_;
        capGuardian = capGuardian_;
        emit CapRaised(0, cap_);
        emit MinterSet(address(0), minter_);
        emit CapGuardianSet(address(0), capGuardian_);
    }

    function version() external pure override returns (string memory) {
        return "APNTsCapped-1.0.0";
    }

    // ------------------------------------------------------------------
    // Minting (cap enforced)
    // ------------------------------------------------------------------

    /// @notice Mint `amount` to `to`. Only the minter; reverts CapExceeded if
    ///         totalSupply() + amount > cap (also when the cap was lowered below supply).
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter(msg.sender);
        uint256 supply = totalSupply();
        // Overflow-free form of `supply + amount > cap`.
        if (amount > cap || supply > cap - amount) revert CapExceeded(supply, amount, cap);
        _mint(to, amount);
        emit Minted(to, amount, supply + amount, cap);
    }

    /// @notice Burn caller's own balance (frees minting room). No third-party burn exists.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Cap governance
    // ------------------------------------------------------------------

    /// @notice Raise the cap. Owner only (the 48h timelock), strictly upwards.
    function raiseCap(uint256 newCap) external onlyOwner {
        uint256 old = cap;
        if (newCap <= old) revert CapNotRaised(old, newCap);
        cap = newCap;
        emit CapRaised(old, newCap);
    }

    /// @notice Lower the cap, immediately. capGuardian or owner, strictly downwards. May go
    ///         below totalSupply: that stops all minting and flips isOverIssued() to true;
    ///         existing balances are untouched.
    function lowerCap(uint256 newCap) external {
        if (msg.sender != capGuardian && msg.sender != owner()) revert NotCapGuardian(msg.sender);
        uint256 old = cap;
        if (newCap >= old) revert CapNotLowered(old, newCap);
        cap = newCap;
        emit CapLowered(old, newCap, msg.sender);
    }

    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert ZeroAddress();
        emit MinterSet(minter, newMinter);
        minter = newMinter;
    }

    function setCapGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit CapGuardianSet(capGuardian, newGuardian);
        capGuardian = newGuardian;
    }

    /// @notice Disabled: an ownerless token could never have its roles rotated.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------
    // Compatibility views (IxPNTsToken observers: DVT rule ③ / reputation)
    // ------------------------------------------------------------------

    /// @notice Same as `cap` — here an ENFORCED ceiling, not an advisory flag.
    function issuanceCap() external view returns (uint256) {
        return cap;
    }

    /// @notice True only after lowerCap took the cap below the current supply.
    function isOverIssued() external view returns (bool) {
        return totalSupply() > cap;
    }

    // ------------------------------------------------------------------
    // ERC-1363-style push transfer (SuperPaymaster.onTransferReceived deposit path)
    // ------------------------------------------------------------------

    function transferAndCall(address to, uint256 amount) external returns (bool) {
        return transferAndCall(to, amount, "");
    }

    /// @notice Transfer to a contract and call `onTransferReceived(operator, from, value, data)`
    ///         with operator = from = msg.sender (the same call xPNTsToken makes). The receiver
    ///         must return the `onTransferReceived` selector.
    /// @dev    Stricter than xPNTsToken 3.5.0 in two ways, both fail-closed: a receiver without
    ///         code reverts (ERC-1363), and a receiver revert is bubbled (not swallowed into a
    ///         generic message), so e.g. SP's `Unauthorized` / role errors reach the caller.
    ///         State is updated before the callback; the callback gets no extra power.
    function transferAndCall(address to, uint256 amount, bytes memory data) public returns (bool) {
        if (to.code.length == 0) revert ReceiverNotContract(to);
        _transfer(msg.sender, to, amount);
        bytes4 retval = IERC1363Receiver(to).onTransferReceived(msg.sender, msg.sender, amount, data);
        if (retval != IERC1363Receiver.onTransferReceived.selector) revert ReceiverRejected(to, retval);
        return true;
    }
}
