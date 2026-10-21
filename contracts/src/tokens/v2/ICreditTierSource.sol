// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice Pluggable credit tier source for xPNTs v2 (spec §8.7).
/// @dev    MUST be `view` (called with STATICCALL) and must not depend on block
///         environment opcodes: it runs inside a paymaster validation frame.
interface ICreditTierSource {
    /// @return tier Credit ceiling in aPNTs for `user` within `community`.
    function tierOf(address community, address user) external view returns (uint256 tier);
}
