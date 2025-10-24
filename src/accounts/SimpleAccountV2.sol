// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable reason-string */

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../../contracts/src/core/BaseAccount.sol";
import "../../contracts/src/core/Helpers.sol";
import "../../contracts/src/callback/TokenCallbackHandler.sol";

/**
  * SimpleAccountV2 - Upgraded version with personal_sign support
  *
  * Changes from V1:
  * - Supports both raw signature (eth_sign) and personal_sign (signMessage)
  * - Uses MessageHashUtils.toEthSignedMessageHash() for personal_sign verification
  * - Backward compatible with V1 signatures
  *
  * This allows MetaMask users to sign UserOperations using personal_sign
  * since eth_sign has been disabled in MetaMask for security reasons.
  */
contract SimpleAccountV2 is BaseAccount, TokenCallbackHandler, UUPSUpgradeable, Initializable {
    address public owner;

    IEntryPoint private immutable _entryPoint;

    event SimpleAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    constructor(IEntryPoint anEntryPoint) {
        _entryPoint = anEntryPoint;
        _disableInitializers();
    }

    function _onlyOwner() internal view {
        // Directly from EOA owner, or through the account itself (which gets redirected through execute())
        require(msg.sender == owner || msg.sender == address(this), "only owner");
    }

    /**
     * @dev The _entryPoint member is immutable, to reduce gas consumption.  To upgrade EntryPoint,
     * a new implementation of SimpleAccount must be deployed with the new EntryPoint address, then upgrading
      * the implementation by calling `upgradeTo()`
      * @param anOwner the owner (signer) of this account
     */
    function initialize(address anOwner) public virtual initializer {
        _initialize(anOwner);
    }

    function _initialize(address anOwner) internal virtual {
        owner = anOwner;
        emit SimpleAccountInitialized(_entryPoint, owner);
    }

    // Require the function call went through EntryPoint or owner
    function _requireForExecute() internal view override virtual {
        require(msg.sender == address(entryPoint()) || msg.sender == owner, "account: not Owner or EntryPoint");
    }

    /// implement template method of BaseAccount
    /// V2: Support both personal_sign and raw eth_sign
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
    internal override virtual returns (uint256 validationData) {

        // Try personal_sign format first (MetaMask signMessage)
        // This adds "\x19Ethereum Signed Message:\n32" prefix
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address recoveredFromPersonalSign = ECDSA.recover(ethSignedMessageHash, userOp.signature);

        if (recoveredFromPersonalSign == owner) {
            return SIG_VALIDATION_SUCCESS;
        }

        // Fallback to raw signature (backward compatibility with V1)
        // This supports eth_sign (if user enables it) or backend signing
        address recoveredFromRaw = ECDSA.recover(userOpHash, userOp.signature);

        if (recoveredFromRaw == owner) {
            return SIG_VALIDATION_SUCCESS;
        }

        return SIG_VALIDATION_FAILED;
    }

    /**
     * check current account deposit in the entryPoint
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * deposit more funds for this account in the entryPoint
     */
    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * withdraw value from the account's deposit
     * @param withdrawAddress target to send to
     * @param amount to withdraw
     */
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal view override {
        (newImplementation);
        _onlyOwner();
    }

    /**
     * Return the version of this account implementation
     */
    function version() public pure virtual returns (string memory) {
        return "2.0.0";
    }
}
