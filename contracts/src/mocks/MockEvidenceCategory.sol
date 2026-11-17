// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "src/interfaces/IEvidenceCategory.sol";

/// @notice Test-only configurable raw-evidence predicate.
contract MockEvidenceCategory is IEvidenceCategory {
    bool public accepted = true;
    bool public shouldRevert;

    function setAccepted(bool value) external {
        accepted = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function check(address, uint8, uint256, bytes calldata) external view override returns (bool) {
        if (shouldRevert) revert("mock evidence rejection");
        return accepted;
    }
}
