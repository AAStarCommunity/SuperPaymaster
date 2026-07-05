// SPDX-License-Identifier: Apache-2.0
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

    // Per-severity slash thresholds (test default mirrors the real bootstrap 2/3/3).
    mapping(uint8 => uint8) private _slashThresholds;

    bool public verifyResult = true;

    constructor() {
        _slashThresholds[0] = 2; // WARNING
        _slashThresholds[1] = 3; // MINOR
        _slashThresholds[2] = 3; // MAJOR
    }

    function slashThresholds(uint8 level) external view override returns (uint8) {
        return _slashThresholds[level];
    }

    function setSlashThreshold(uint8 level, uint8 threshold) external {
        _slashThresholds[level] = threshold;
    }

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
        uint256, address, uint8, address[] calldata, uint256[] calldata, uint256, bytes32, bytes calldata
    ) external pure override {}

    function setDVTValidator(address) external pure override {}
}
