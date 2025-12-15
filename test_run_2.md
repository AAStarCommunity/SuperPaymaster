Starting Anvil...
Anvil started with PID 35524
Deploying Contracts locally...
❌ Deployment Failed. Check script/v3/logs/deploy.log
Warning: Found unknown `exclude` config for profile `default` defined in foundry.toml.
Compiling 121 files with Solc 0.8.28
Solc 0.8.28 finished in 2.04s
Error: Compiler run failed:
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

Error (9553): Invalid type for argument in function call. Invalid implicit conversion from address to contract IRegistryV3 requested.
  --> script/v3/SetupV3.s.sol:99:89:
   |
99 |         superPaymaster = new SuperPaymasterV3(IEntryPoint(entryPointAddress), deployer, address(registry), aPNTsAddr, priceFeedAddr, treasury);
   |                                                                                         ^^^^^^^^^^^^^^^^^
Stopping Anvil...
