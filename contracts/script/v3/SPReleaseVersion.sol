// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice Single source of truth for the SuperPaymaster / lens version strings every release script
///         reads back (V55Bootstrap and everything inheriting it, Check08, Check09, InitializeAAStar).
/// @dev    exp/buffer-and-params: experiment versions. A real release picks the final strings here
///         (and in SuperPaymaster.version() / SuperPaymasterLens) — SPReleaseVersionPinTest keeps the
///         three in lock-step.
library SPReleaseVersion {
    string internal constant SP = "SuperPaymaster-5.5.1-exp";
    string internal constant LENS = "SuperPaymasterLens-1.1.0-exp";
}
