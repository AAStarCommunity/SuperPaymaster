// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";

interface IHandoverOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

library TimelockHandover {
    function batch(TimelockController t, address[] memory owned, address h)
        internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](owned.length + 4);
        values = new uint256[](targets.length);
        data = new bytes[](targets.length);
        for (uint256 i; i < owned.length; ++i) {
            targets[i] = owned[i];
            data[i] = abi.encodeWithSignature("acceptOwnership()");
        }
        bytes32[3] memory roles = [keccak256("PROPOSER_ROLE"), keccak256("EXECUTOR_ROLE"), keccak256("CANCELLER_ROLE")];
        for (uint256 i; i < 3; ++i) {
            targets[owned.length + i] = address(t);
            data[owned.length + i] = abi.encodeCall(t.revokeRole, (roles[i], h));
        }
        targets[owned.length + 3] = address(t);
        data[owned.length + 3] = abi.encodeCall(t.updateDelay, (172800));
    }

    function assertFinal(TimelockController t, address[] memory owned, address safe, address deployer, address h)
        internal view
    {
        require(t.getMinDelay() == 172800, "handover: delay");
        bytes32[4] memory roles = [t.DEFAULT_ADMIN_ROLE(), t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
        for (uint256 i; i < 4; ++i) {
            require(!t.hasRole(roles[i], deployer), "handover: deployer role");
            require(!t.hasRole(roles[i], h), "handover: bootstrap role");
            require(t.hasRole(roles[i], safe) == (i != 0), "handover: safe role");
            require(t.hasRole(roles[i], address(t)) == (i == 0), "handover: timelock role");
            require(!t.hasRole(roles[i], address(0)), "handover: open role");
        }
        for (uint256 i; i < owned.length; ++i) {
            require(IHandoverOwned(owned[i]).owner() == address(t), "handover: owner");
            require(IHandoverOwned(owned[i]).pendingOwner() == address(0), "handover: pending owner");
        }
    }
}

/// @notice Constructor-only, one-shot handover; no callable runtime surface.
contract TimelockHandoverBootstrap {
    error BootstrapRolesMissing();

    constructor(TimelockController t, address[] memory owned) {
        if (!t.hasRole(t.PROPOSER_ROLE(), address(this)) || !t.hasRole(t.EXECUTOR_ROLE(), address(this))) {
            revert BootstrapRolesMissing();
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory data) =
            TimelockHandover.batch(t, owned, address(this));
        bytes32 salt = keccak256(abi.encode(address(this), owned));
        t.scheduleBatch(targets, values, data, bytes32(0), salt, 0);
        t.executeBatch(targets, values, data, bytes32(0), salt);
    }
}
