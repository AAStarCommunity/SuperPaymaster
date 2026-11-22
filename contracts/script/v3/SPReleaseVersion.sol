// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice Single source of truth for the SuperPaymaster / lens version strings every release script
///         reads back (V55Bootstrap and everything inheriting it, Check08, Check09, InitializeAAStar).
/// @dev    The rc.8 review fixes report "SuperPaymaster-5.5.4";
///         SPReleaseVersionPinTest keeps SP.version(), the lens
///         version() and lens.EXPECTED_SP_VERSION in lock-step with these constants.
library SPReleaseVersion {
    string internal constant SP = "SuperPaymaster-5.5.4";
    string internal constant LENS = "SuperPaymasterLens-1.2.5";
}
