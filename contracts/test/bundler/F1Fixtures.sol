// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@account-abstraction-v7/interfaces/IAccount.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * D5 gate G1 — F1 investigation fixtures (docs/design/aoa-balance-mode/b-layer/F1-investigation.md).
 * Local nodes only; nothing here is deployed outside a local anvil.
 */

interface IXPNTsEscrowView {
    function lockedOf(address user) external view returns (uint256);
    function creditReservedOf(address user) external view returns (uint256);
}

/// @notice MockAirAccount + an ACCOUNT-SIDE GUARD: validateUserOp refuses while the xPNTs v2 token
///         still holds an escrow for this account (lockedOf / creditReservedOf of address(this),
///         both sender-associated slots, STO-021). `guardMode` 1 = return SIG_VALIDATION_FAILED
///         (EntryPoint: AA24), 2 = revert (EntryPoint: AA23).
contract MockAirAccountGuarded is IAccount {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    address public immutable ENTRY_POINT;
    address public immutable GUARD_TOKEN;
    uint8 public immutable GUARD_MODE;
    address public owner;

    error EscrowPending(uint256 locked, uint256 reserved);

    constructor(address entryPoint, address owner_, address token, uint8 mode) {
        require(mode == 1 || mode == 2, "mode");
        ENTRY_POINT = entryPoint;
        owner = owner_;
        GUARD_TOKEN = token;
        GUARD_MODE = mode;
    }

    function validateUserOp(PackedUserOperation calldata op, bytes32 userOpHash, uint256 missingFunds)
        external returns (uint256 validationData)
    {
        require(msg.sender == ENTRY_POINT, "ep");
        uint256 locked = IXPNTsEscrowView(GUARD_TOKEN).lockedOf(address(this));
        uint256 reserved = IXPNTsEscrowView(GUARD_TOKEN).creditReservedOf(address(this));
        if (locked != 0 || reserved != 0) {
            if (GUARD_MODE == 2) revert EscrowPending(locked, reserved);
            return SIG_VALIDATION_FAILED;
        }
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(userOpHash), op.signature);
        validationData = signer == owner ? 0 : SIG_VALIDATION_FAILED;
        if (missingFunds != 0) {
            (bool ok, ) = payable(msg.sender).call{value: missingFunds}("");
            ok;
        }
    }

    function execute(address to, uint256 value, bytes calldata data) external {
        require(msg.sender == ENTRY_POINT, "ep");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }

    receive() external payable {}
}

/// @notice Plain ERC-20 for the TokenPaymaster control (any holder may be minted to by the deployer).
contract F1TestToken is ERC20 {
    address public immutable MINTER;
    constructor() ERC20("F1 Control Token", "F1T") { MINTER = msg.sender; }
    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, "minter");
        _mint(to, amount);
    }
}

/// @notice IOracle for TokenPaymaster: 1 token = 1 native (8 decimals), always fresh.
contract F1Oracle {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, 0, block.timestamp, 1);
    }
}
