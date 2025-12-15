Starting Anvil...
Anvil started with PID 36501
Deploying Contracts locally...
❌ Deployment Failed. Check script/v3/logs/deploy.log
Warning: Found unknown `exclude` config for profile `default` defined in foundry.toml.
Compiling 121 files with Solc 0.8.28
Solc 0.8.28 finished in 122.14s
Compiler run successful with warnings:
Warning (2519): This declaration shadows an existing declaration.
   --> contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol:289:5:
    |
289 |     function _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
    |     ^ (Relevant source part starts here and spans across multiple lines).
Note: The shadowed declaration is here:
  --> singleton-paymaster/lib/account-abstraction-v7/contracts/core/Helpers.sol:59:1:
   |
59 | function _packValidationData(
   | ^ (Relevant source part starts here and spans across multiple lines).
Note: The shadowed declaration is here:
  --> singleton-paymaster/lib/account-abstraction-v7/contracts/core/Helpers.sol:74:1:
   |
74 | function _packValidationData(
   | ^ (Relevant source part starts here and spans across multiple lines).

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol:564:9:
    |
564 |         bytes32 userOpHash,
    |         ^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol:657:9:
    |
657 |         bytes memory proof  // NOTE: Reserved for future BLS verification
    |         ^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol:180:9:
    |
180 |         bytes32 userOpHash,
    |         ^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol:293:9:
    |
293 |         uint256 tokenId,
    |         ^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol:294:9:
    |
294 |         address community,
    |         ^^^^^^^^^^^^^^^^^

Warning (2072): Unused local variable.
   --> contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol:302:9:
    |
302 |         uint256 startWeek = currentWeek - (timeWindow / 1 weeks);
    |         ^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/v2/extensions/MySBTReputationAccumulator.sol:317:53:
    |
317 |     function _calculateTimeWeight(uint256 joinTime, uint256 decayFactor) internal view returns (uint256 weight) {
    |                                                     ^^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/paymasters/v2/monitoring/BLSAggregator.sol:300:9:
    |
300 |         bytes32 messageHash,
    |         ^^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
  --> contracts/src/paymasters/v4/PaymasterV4_1i.sol:76:9:
   |
76 |         uint256 _minTokenBalance, // for compatibility with registry deployment
   |         ^^^^^^^^^^^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/tokens/MySBT.sol:273:40:
    |
273 |     function mintForRole(address user, bytes32 roleId, bytes calldata roleData)
    |                                        ^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
   --> contracts/src/tokens/MySBT.sol:347:37:
    |
347 |     function airdropMint(address u, bytes32 roleId, bytes calldata roleData)
    |                                     ^^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
  --> contracts/src/utils/FactoryHelper.sol:29:47:
   |
29 |     function addAutoApprovedSpenderViaFactory(address token, address spender) external {
   |                                               ^^^^^^^^^^^^^

Warning (5667): Unused function parameter. Remove or comment out the variable name to silence this warning.
  --> contracts/src/utils/FactoryHelper.sol:29:62:
   |
29 |     function addAutoApprovedSpenderViaFactory(address token, address spender) external {
   |                                                              ^^^^^^^^^^^^^^^

Warning (2018): Function state mutability can be restricted to pure
    --> contracts/src/core/Registry.sol:1383:5:
     |
1383 |     function getBestPaymaster() external view returns (address, uint256) {
     |     ^ (Relevant source part starts here and spans across multiple lines).

Warning (2018): Function state mutability can be restricted to pure
    --> contracts/src/core/Registry.sol:1387:5:
     |
1387 |     function getActivePaymasters() external view returns (address[] memory) {
     |     ^ (Relevant source part starts here and spans across multiple lines).

Warning (2018): Function state mutability can be restricted to pure
    --> contracts/src/core/Registry.sol:1391:5:
     |
1391 |     function getRouterStats() external view returns (uint256, uint256, uint256, uint256) {
     |     ^ (Relevant source part starts here and spans across multiple lines).

Warning (2018): Function state mutability can be restricted to pure
   --> contracts/src/paymasters/v2/monitoring/BLSAggregator.sol:468:5:
    |
468 |     function getActiveValidatorCount() external view returns (uint256 count) {
    |     ^ (Relevant source part starts here and spans across multiple lines).

Warning (2018): Function state mutability can be restricted to view
  --> contracts/src/utils/FactoryHelper.sol:29:5:
   |
29 |     function addAutoApprovedSpenderViaFactory(address token, address spender) external {
   |     ^ (Relevant source part starts here and spans across multiple lines).

Error: Multiple contracts in the target path. Please specify the contract name with `--tc ContractName`
Stopping Anvil...
