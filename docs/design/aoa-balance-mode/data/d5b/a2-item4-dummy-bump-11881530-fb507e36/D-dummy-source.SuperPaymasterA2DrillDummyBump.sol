// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// Wildcard import: brings SuperPaymaster plus IEntryPoint / IRegistry exactly as the release source sees them.
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

/**
 * @title  SuperPaymasterA2DrillDummyBump — TEST ARTIFACT, NOT A RELEASE ARTIFACT
 * @notice rc1' "dummy bump" for the A2 timelock-aware upgrade drill (03-final-spec.md §6, rc1 gate
 *         item 4; CC-124). It exists ONLY to give the fork rehearsal an implementation whose runtime
 *         differs from the v5.5.0-rc.2 SuperPaymaster, so that "schedule(upgradeToAndCall) -> 48h ->
 *         execute" is proven to switch code, not merely to re-point the proxy at identical bytes.
 *
 *         The ONLY change versus the rc.2 SuperPaymaster is one harmless constant: the string
 *         returned by version(). No state variable is declared here, so the storage layout is the
 *         rc.2 layout by construction (the drill also diffs the two compiler storage layouts).
 *         The constructor forwards the same three immutables, so EXTENSION is a fresh
 *         SuperPaymasterAdmin built from the same (rc.2) source.
 *
 *         It lives under contracts/test/ on purpose: it is never deployed to a public network, never
 *         listed in docs/release/*-attestation.json, and must never be used for a real upgrade.
 */
contract SuperPaymasterA2DrillDummyBump is SuperPaymaster {
    /// @dev The test-only marker the drill reads back through the proxy.
    string internal constant DRILL_VERSION = "SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE";

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint _entryPoint, IRegistry _registry, address _ethUsdPriceFeed)
        SuperPaymaster(_entryPoint, _registry, _ethUsdPriceFeed)
    { }

    function version() external pure override returns (string memory) {
        return DRILL_VERSION;
    }
}
