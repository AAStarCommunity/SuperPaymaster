# Gasless Transfer Test Cases

E2E gasless transfer tests for SuperPaymaster v4.1.0 (UUPS Proxy).

## Contract Addresses

All addresses are loaded dynamically from `deployments/config.sepolia.json`. No hardcoded addresses in test scripts.

### Test Case 1: PaymasterV4 + aPNTs
- **Paymaster**: PaymasterV4 (looked up via `PaymasterFactory.paymasterByOperator`)
- **Token**: aPNTs (from config)
- **EntryPoint**: v0.7 `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

### Test Case 2: SuperPaymaster + aPNTs
- **Paymaster**: SuperPaymaster UUPS Proxy (from config)
- **Token**: aPNTs (from config)
- **EntryPoint**: v0.7

### Test Case 3: SuperPaymaster + aPNTs (different AA account)
- **Paymaster**: SuperPaymaster UUPS Proxy (from config)
- **Token**: aPNTs (from config)
- **EntryPoint**: v0.7

## Environment Configuration

All test scripts read from `.env.sepolia` in the project root (override via `ENV_FILE`):

- `SEPOLIA_RPC_URL`: Sepolia RPC endpoint
- `OWNER_PRIVATE_KEY` / `DEPLOYER_PRIVATE_KEY`: Sender private key
- `OWNER2_ADDRESS` / `TEST_EOA_ADDRESS`: Recipient address
- `TEST_AA_ACCOUNT_ADDRESS_A/B/C`: SimpleAccount (AA) addresses
- `OPERATOR_ADDRESS`: SuperPaymaster operator (default: Anni)

**Important**: Private keys and RPC URLs are NOT committed to the repo.

## Running Tests

### Prerequisites

```bash
# Install global dependencies (ethers v6 + dotenv)
npm install -g ethers dotenv

# Or install locally
cd script/gasless-tests && pnpm install ethers dotenv
```

### Run individual tests

```bash
# Check all deployed contracts
node script/gasless-tests/check-contracts.js

# Check token balances
node script/gasless-tests/check-balances.js

# Test Case 1: PaymasterV4
node script/gasless-tests/test-case-1-paymasterv4.js

# Test Case 2: SuperPaymaster
node script/gasless-tests/test-case-2-superpaymaster-xpnts1.js

# Test Case 3: SuperPaymaster (different account)
node script/gasless-tests/test-case-3-superpaymaster-xpnts2.js
```

### Run all tests

```bash
./script/gasless-tests/run-all-tests.sh
```

## Test Flow

Each test script:

1. **Load Config**: Read addresses from `config.sepolia.json` + env vars
2. **Balance Check**: Verify AA account has aPNTs tokens
3. **Build CallData**: Create ERC20 transfer calldata
4. **Build UserOperation**: EIP-4337 v0.7 PackedUserOperation
5. **Sign**: EOA signs UserOp hash from EntryPoint
6. **Submit**: Call `EntryPoint.handleOps()`
7. **Verify**: Confirm transaction and check final balances

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `AA10 sender already constructed` | AA account not deployed, empty initCode | Check AA account deployment |
| `AA21 didn't pay prefund` | Paymaster ETH balance insufficient | Deposit ETH to Paymaster in EntryPoint |
| `AA24 signature error` | Wrong signature format | Use EntryPoint.getUserOpHash for canonical hash |
| `AA30 paymaster not deployed` | Wrong paymaster address | Verify address in config.sepolia.json |

## Directory Structure

```
script/gasless-tests/
├── load-config.js                                # Shared config loader
├── check-contracts.js                            # Verify all contracts deployed + versions
├── check-balances.js                             # Check token + ETH deposit balances
├── mint-tokens.js                                # Mint aPNTs to AA accounts
├── transfer-tokens.js                            # Transfer aPNTs to AA accounts
├── test-case-1-paymasterv4.js                    # Test 1: PaymasterV4 + aPNTs
├── test-case-2-superpaymaster-xpnts1.js          # Test 2: SuperPaymaster + aPNTs
├── test-case-2-superpaymaster-xpnts1-fixed.js    # Test 2 (with allowance check)
├── test-case-3-superpaymaster-xpnts2.js          # Test 3: SuperPaymaster + aPNTs
├── run-all-tests.sh                              # Run all test cases
└── README.md                                     # This file
```
