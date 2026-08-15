// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title  MockUnderCapXPNTs — CC-89 Phase-2 E2E over-issue token stand-in
/// @notice The over-issue fraud-proof verifier reads `isOverIssued()` on the disputed
///         token. For the E2E we need a token that is NOT over-issued, so a guardian
///         proposal accusing it of over-issuance is provably false → guardians slashed.
///         Returns a self-consistent "healthy" view (issued << cap) so any recompute
///         path (issuedValueUSD vs effectiveCapUSD, totalSupply vs issuanceCap) also
///         reads not-over-issued. Testnet E2E stand-in only.
contract MockUnderCapXPNTs {
    function isOverIssued() external pure returns (bool) { return false; }
    function totalSupply() external pure returns (uint256) { return 1_000 ether; }
    function issuanceCap() external pure returns (uint256) { return 0; }           // unset → no absolute breach
    function issuedValueUSD() external pure returns (uint256) { return 100 ether; }  // $100 issued
    function effectiveCapUSD() external pure returns (uint256) { return 10_000 ether; } // $10k cap
    function credibilityScore() external pure returns (uint8) { return 100; }
    function FACTORY() external view returns (address) { return address(this); }     // non-zero → verifiable
    function name() external pure returns (string memory) { return "E2E UnderCap xPNTs"; }
    function symbol() external pure returns (string memory) { return "E2EOK"; }
    function decimals() external pure returns (uint8) { return 18; }
}
