// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@account-abstraction-v7/interfaces/IAccount.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * D5 gate G1 — B4 / B6 fixtures (docs/design/aoa-balance-mode/D5-plan.md §3.3). Local nodes only.
 *
 * MockAirAccount stands in for an AirAccount that implements spec option A (D-18): when the
 * op's signature carries a trailing flag byte 0x01, `validateUserOp` calls
 * `token.renewForSelf(spender)` — so the bundler traces the token frame INSIDE the unstaked
 * account's validation (§2.3 row 55: only slots keyed by the sender may be touched).
 */
interface IRenewForSelf {
    function renewForSelf(address spender) external;
}

interface IEntryPointDeposit {
    function depositTo(address account) external payable;
    function addStake(uint32 unstakeDelaySec) external payable;
}

contract MockAirAccount is IAccount {
    address public immutable ENTRY_POINT;
    address public owner;
    address public renewToken;
    address public renewSpender;

    constructor(address entryPoint) { ENTRY_POINT = entryPoint; }

    function initialize(address owner_, address token_, address spender_) external {
        require(owner == address(0), "init");
        owner = owner_;
        renewToken = token_;
        renewSpender = spender_;
    }

    function validateUserOp(PackedUserOperation calldata op, bytes32 userOpHash, uint256 missingFunds)
        external returns (uint256 validationData)
    {
        require(msg.sender == ENTRY_POINT, "ep");
        bytes calldata sig = op.signature;
        bool renew = sig.length == 66 && sig[65] == 0x01;
        bytes calldata ecdsa = sig.length == 66 ? sig[:65] : sig;
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(userOpHash), ecdsa);
        validationData = signer == owner ? 0 : 1;
        if (renew && validationData == 0) {
            // option A: account-mediated renewal inside the validation frame
            IRenewForSelf(renewToken).renewForSelf(renewSpender);
        }
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

/// @notice CREATE2 factory for MockAirAccount. It records every deployment in ITS OWN storage,
///         so under ERC-7562 it needs stake (STO-031): B4 runs it above and below the bundlers'
///         thresholds and asserts the specific rejection reason below.
contract MockAirAccountFactory {
    address public immutable ENTRY_POINT;
    uint256 public deployments;

    constructor(address entryPoint) { ENTRY_POINT = entryPoint; }

    function createAccount(address owner, address token, address spender, uint256 salt)
        external returns (MockAirAccount acct)
    {
        address predicted = getAddress(salt);
        if (predicted.code.length != 0) return MockAirAccount(payable(predicted));
        acct = new MockAirAccount{salt: bytes32(salt)}(ENTRY_POINT);
        acct.initialize(owner, token, spender);
        deployments += 1;
    }

    function getAddress(uint256 salt) public view returns (address) {
        bytes32 h = keccak256(abi.encodePacked(
            bytes1(0xff), address(this), bytes32(salt),
            keccak256(abi.encodePacked(type(MockAirAccount).creationCode, abi.encode(ENTRY_POINT)))
        ));
        return address(uint160(uint256(h)));
    }

    function stake(uint32 unstakeDelaySec) external payable {
        IEntryPointDeposit(ENTRY_POINT).addStake{value: msg.value}(unstakeDelaySec);
    }
}
