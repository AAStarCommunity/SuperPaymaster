Starting Anvil...
Anvil started with PID 34862
Deploying Contracts locally...
❌ Deployment Failed. Check script/v3/logs/deploy.log
Warning: Found unknown `exclude` config for profile `default` defined in foundry.toml.
Compiling 121 files with Solc 0.8.28
Solc 0.8.28 finished in 2.01s
Error: Compiler run failed:
Warning (2519): This declaration shadows an existing declaration.
   --> contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:289:5:
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

Error (6160): Wrong argument count for function call: 5 arguments given but expected 6.
  --> script/v3/SetupV3.s.sol:89:26:
   |
89 |         superPaymaster = new SuperPaymaster(entryPointAddress, deployer, address(registry), priceFeedAddr, treasury);
   |                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Error (6160): Wrong argument count for function call: 1 arguments given but expected 2.
   --> script/v3/SetupV3.s.sol:103:24:
    |
103 |         xpntsFactory = new xPNTsFactory(address(registry));
    |                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Error (7398): Explicit type conversion not allowed from non-payable "address" to "contract PaymasterV4_1i", which has a payable fallback function.
   --> script/v3/SetupV3.s.sol:115:43:
    |
115 |         PaymasterV4_1i paymasterV4Proxy = PaymasterV4_1i(proxyAddr);
    |                                           ^^^^^^^^^^^^^^^^^^^^^^^^^
Note: Did you mean to declare this variable as "address payable"?
   --> script/v3/SetupV3.s.sol:114:9:
    |
114 |         address proxyAddr = paymasterFactory.deployPaymasterDefault("");
    |         ^^^^^^^^^^^^^^^^^
Stopping Anvil...
