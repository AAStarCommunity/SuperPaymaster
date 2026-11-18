// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";

interface IHandoverOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

library TimelockHandover {
    function batch(TimelockController t, address[] memory owned, address h, address safe)
        internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](owned.length + 7);
        values = new uint256[](targets.length);
        data = new bytes[](targets.length);
        for (uint256 i; i < owned.length; ++i) {
            targets[i] = owned[i];
            data[i] = abi.encodeWithSignature("acceptOwnership()");
        }
        bytes32[3] memory roles = [keccak256("PROPOSER_ROLE"), keccak256("EXECUTOR_ROLE"), keccak256("CANCELLER_ROLE")];
        for (uint256 i; i < 3; ++i) {
            targets[owned.length + i] = address(t);
            data[owned.length + i] = abi.encodeCall(t.grantRole, (roles[i], safe));
            targets[owned.length + 3 + i] = address(t);
            data[owned.length + 3 + i] = abi.encodeCall(t.revokeRole, (roles[i], h));
        }
        targets[owned.length + 6] = address(t);
        data[owned.length + 6] = abi.encodeCall(t.updateDelay, (172800));
    }

    function assertFinal(TimelockController t, address[] memory owned, address safe, address[] memory subjects)
        internal view
    {
        require(t.getMinDelay() == 172800, "handover: delay");
        bytes32[4] memory roles = [t.DEFAULT_ADMIN_ROLE(), t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < subjects.length; ++j) {
                // GOVERNOR_ADDRESS may be the Safe; its expected roles are checked below.
                if (subjects[j] != safe) require(!t.hasRole(roles[i], subjects[j]), "handover: unexpected role");
            }
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

    constructor(TimelockController t, address[] memory owned, address safe) {
        if (!t.hasRole(t.PROPOSER_ROLE(), address(this)) || !t.hasRole(t.EXECUTOR_ROLE(), address(this))) {
            revert BootstrapRolesMissing();
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory data) =
            TimelockHandover.batch(t, owned, address(this), safe);
        bytes32 salt = keccak256(abi.encode(address(this), owned));
        t.scheduleBatch(targets, values, data, bytes32(0), salt, 0);
        t.executeBatch(targets, values, data, bytes32(0), salt);
    }
}
