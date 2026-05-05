// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "src/interfaces/v3/IBLSAggregator.sol";

/**
 * @title MockBLSAggregator
 * @notice Mock aggregator for unit tests — bypasses real BLS pairing.
 * @dev    Returns true from `verify(...)` regardless of inputs. DO NOT USE
 *         IN PRODUCTION. Replaces the deleted MockBLSValidator after the
 *         P0-1 refactor routed all signature verification through the
 *         aggregator.
 */
contract MockBLSAggregator is IBLSAggregator {
    uint256 public override minThreshold = 3;
    uint256 public override defaultThreshold = 7;

    bool public verifyResult = true;

    function setVerifyResult(bool ok) external {
        verifyResult = ok;
    }

    function setThresholds(uint256 _min, uint256 _default) external {
        minThreshold = _min;
        defaultThreshold = _default;
    }

    function verify(
        bytes32 /*expectedMessageHash*/,
        uint256 /*signerMask*/,
        uint256 /*requiredThreshold*/,
        bytes calldata /*sigBytes*/
    ) external view override returns (bool) {
        return verifyResult;
    }

    function verifyAndExecute(
        uint256, address, uint8, address[] calldata, uint256[] calldata, uint256, bytes calldata
    ) external pure override {}

    function setDVTValidator(address) external pure override {}
}
