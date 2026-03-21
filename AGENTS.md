# SuperPaymaster - Agent Guidelines

## Project Overview

SuperPaymaster is a **decentralized gas payment infrastructure** for ERC-4337 Account Abstraction, built with Foundry (Solidity 0.8.33). It enables communities to sponsor gas fees for users via community tokens (xPNTs) instead of ETH.

### Two Operating Modes

- **AOA+ Mode** (SuperPaymaster): Shared multi-operator paymaster with Registry-based community management
- **AOA Mode** (PaymasterV4): Independent per-community paymasters deployed via EIP-1167 minimal proxy factory

### Key Technologies

- **Solidity 0.8.33** with Cancun EVM target
- **Foundry** for compilation, testing, and deployment
- **ERC-4337** Account Abstraction (EntryPoint v0.7)
- **UUPS Proxy Pattern** for upgradeable contracts
- **EIP-1167** Minimal Proxy for PaymasterV4 factory
- **Chainlink Price Feeds** for token pricing
- **Echidna** for fuzz testing
- **The Graph** for event indexing (subgraph)

---

## Project Structure

```
.
├── contracts/
│   ├── src/                    # Core Solidity contracts
│   │   ├── core/               # Registry, GTokenStaking
│   │   ├── tokens/             # GToken, MySBT, xPNTs
│   │   ├── paymasters/         # SuperPaymaster (v3), PaymasterV4
│   │   ├── modules/            # BLSValidator, DVTValidator, ReputationSystem
│   │   ├── interfaces/         # All interface definitions
│   │   └── accounts/           # SimpleAccount, SimpleAccountFactory
│   ├── test/                   # Foundry test files (*.t.sol)
│   │   ├── v3/                 # V3 contract tests
│   │   ├── v4/                 # V4 contract tests
│   │   ├── paymasters/         # Paymaster-specific tests
│   │   └── modules/            # DVT/BLS validator tests
│   ├── script/                 # Forge deployment scripts (*.s.sol)
│   │   ├── v3/                 # V3 deployment orchestration
│   │   ├── v4/                 # V4 deployment scripts
│   │   ├── checks/             # Post-deployment verification scripts
│   │   └── deployment/         # Step-by-step deployment scripts
│   └── lib/                    # Dependencies (foundry-installed)
│       ├── openzeppelin-contracts
│       ├── chainlink-brownie-contracts
│       ├── solady
│       └── forge-std
├── script/                     # Root-level tooling
│   └── gasless-tests/          # E2E gasless transaction tests (JS)
├── deployments/                # Deployment configs (config.<network>.json)
├── abis/                       # Extracted ABI JSONs
├── singleton-paymaster/        # Git submodule - Pimlico paymaster base
├── subgraph/                   # The Graph indexing configuration
├── foundry.toml                # Foundry configuration
├── deploy-core                 # Main deployment script
├── run_full_regression.sh      # Full regression test suite
└── echidna*.yaml               # Fuzz testing configurations
```

---

## Build, Test, and Development Commands

### Building

```bash
# Build all contracts
forge build

# Build only V3 contracts (faster, excludes legacy versions)
forge build --profile v3-only

# Format Solidity code
forge fmt
```

### Testing

```bash
# Run all tests
forge test

# Run a specific test file
forge test --match-path contracts/test/v3/Registry.t.sol

# Run a specific test function
forge test --match-test testRegisterCommunity

# Run with verbose output (levels: -v, -vv, -vvv, -vvvv)
forge test -vvvv

# Run with gas report
forge test --gas-report

# Run coverage
forge coverage
```

### Fuzz Testing (Echidna)

```bash
# Standard fuzz test
echidna . --config echidna.yaml

# Extended run (longer timeout)
echidna . --config echidna-long-run.yaml

# All contracts
echidna . --config echidna-all-contracts.yaml
```

### Deployment

```bash
# Deploy core contracts to a target environment
./deploy-core <env>          # env: anvil, sepolia, op-sepolia, optimism
./deploy-core anvil --force  # Force redeploy even if code unchanged

# Prepare test accounts after deployment
./prepare-test <env>

# Full regression (deploy + verification)
./run_full_regression.sh
./run_full_regression.sh --env sepolia --force

# Check deployed contract versions on-chain
./version-check-onchain.sh
```

### E2E Testing (Gasless Transactions)

```bash
# After deployment and prepare-test, run E2E tests
cd script/gasless-tests && ./run-all-tests.sh
```

### ABI Management

```bash
# Sync ABIs to SDK
./sync_to_sdk.sh
```

---

## Code Style Guidelines

### Solidity Conventions

- **Solidity Version**: 0.8.33 (strict pragma)
- **EVM Target**: Cancun
- **Style**: Follow `forge fmt` output
- **Comments**: All comments in English
- **License**: SPDX-License-Identifier: MIT

### Contract Versioning

All contracts MUST implement a `version()` function returning a semantic version string:

```solidity
function version() external pure virtual returns (string memory) {
    return "ContractName-X.Y.Z";
}
```

Examples:
- `Registry-4.1.0`
- `SuperPaymaster-3.2.2`
- `PaymasterV4-4.3.0`

### Naming Conventions

- **Contracts**: PascalCase (e.g., `SuperPaymaster`, `GTokenStaking`)
- **Functions**: camelCase (e.g., `validatePaymasterUserOp`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `ROLE_COMMUNITY`, `ENTRY_POINT_V07`)
- **Storage Variables**: camelCase with meaningful prefixes
- **Events**: PascalCase with descriptive names (e.g., `CommunityRegistered`)
- **Errors**: PascalCase with descriptive names (e.g., `InvalidRoleConfiguration`)

### Import Order

```solidity
// 1. SPDX and pragma
// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// 2. External dependencies (OpenZeppelin, Chainlink)
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// 3. Internal interfaces
import "../interfaces/v3/IRegistry.sol";

// 4. Internal contracts/libraries
import "../core/GTokenStaking.sol";
```

### Remappings (from foundry.toml)

```
@openzeppelin/contracts/   → contracts/lib/openzeppelin-contracts/contracts/
@openzeppelin-v5.0.2/     → singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/
@account-abstraction-v7/  → singleton-paymaster/lib/account-abstraction-v7/contracts/
account-abstraction/       → lib/account-abstraction/contracts/
@chainlink/contracts/      → contracts/lib/chainlink-brownie-contracts/contracts/
solady/                    → contracts/lib/solady/src/
src/                       → contracts/src/
```

---

## Testing Guidelines

### Test File Organization

- Test files end with `.t.sol`
- Test functions start with `test` (e.g., `testRegisterCommunity`)
- Fuzz tests use `invariant` or `fuzz` prefixes
- Place tests in appropriate subdirectories matching `contracts/src/` structure

### Test Structure

```solidity
contract MyContractTest is Test {
    MyContract contract;
    
    function setUp() public {
        // Deploy contracts
        contract = new MyContract();
    }
    
    function test_SpecificScenario() public {
        // Arrange
        vm.prank(user);
        
        // Act
        contract.doSomething();
        
        // Assert
        assertEq(result, expected);
    }
}
```

### Key Testing Patterns

- Use `vm.prank()` for single-call impersonation
- Use `vm.startPrank()` / `vm.stopPrank()` for multi-call impersonation
- Use `vm.expectRevert()` for testing revert conditions
- Use `vm.expectEmit()` for testing event emissions
- Use `vm.warp()` for timestamp manipulation
- Use `vm.roll()` for block number manipulation

### Test Categories

1. **Unit Tests**: Individual contract functionality
2. **Integration Tests**: Cross-contract interactions
3. **Security Tests**: Access control, edge cases, attack vectors
4. **Gas Optimization Tests**: Verify gas efficiency
5. **Invariant Tests**: Property-based testing with Echidna

---

## Architecture Details

### Core Contracts (Deployment Order Matters)

1. **GToken** (`tokens/GToken.sol`)
   - ERC20 governance token with 21M cap
   - Mintable, burnable, transferable

2. **GTokenStaking** (`core/GTokenStaking.sol`)
   - Role-based staking with true burn mechanism
   - Slashing capabilities for misbehavior

3. **MySBT** (`tokens/MySBT.sol`)
   - Soulbound Token for identity + reputation tracking
   - Non-transferable membership NFT

4. **Registry** (`core/Registry.sol`)
   - Community/node registration
   - Role management and slashing
   - UUPS upgradeable

5. **xPNTsFactory + xPNTsToken** (`tokens/`)
   - Community gas token factory (Clones-based)
   - Creates ERC20 tokens for gas sponsorship

6. **SuperPaymaster** (`paymasters/superpaymaster/v3/`)
   - AOA+ shared paymaster
   - Chainlink oracle integration for pricing
   - xPNTs-based gas pricing
   - Debt tracking system

7. **PaymasterV4** (`paymasters/v4/`)
   - AOA independent mode
   - EIP-1167 minimal proxy pattern
   - Per-community dedicated paymaster

### Supporting Modules

- **BLSValidator** (`modules/validators/`): BLS signature validation (BLS12-381)
- **DVTValidator + BLSAggregator** (`modules/monitoring/`): Distributed validator technology
- **ReputationSystem** (`modules/reputation/`): Reputation scoring with community rules

### Contract Dependencies

```
GToken
  ├── GTokenStaking
  │     └── Registry
  │           ├── MySBT
  │           ├── SuperPaymaster
  │           └── xPNTsFactory
  └── MySBT
```

---

## Deployment Process

### Environment Configuration

Environment files are `.env.<network>` where `<network>` is one of:
- `anvil` - Local testing
- `sepolia` - Ethereum testnet
- `op-sepolia` - Optimism testnet
- `optimism` - Optimism mainnet
- `mainnet` - Ethereum mainnet

### Deployment Workflow (`deploy-core`)

1. **Load Environment**: Source `.env.<env>` for RPC URL and credentials
2. **Hash Check**: Compute SHA256 of all `contracts/src/*.sol` files
3. **Skip Logic**: Skip deploy if hash matches stored config (non-anvil only)
4. **Signer Selection** (priority order):
   - `DEPLOYER_ACCOUNT` (Foundry keystore) - RECOMMENDED
   - `PRIVATE_KEY` (plaintext) - NOT RECOMMENDED
   - Anvil default key (anvil only)
5. **Execute Deployment**: Run `DeployAnvil.s.sol` or `DeployLive.s.sol`
6. **Verification**: Run 7 verification check scripts (Check01–Check09, VerifyV3_1_1)

### Deployment Config Files

Stored in `deployments/config.<network>.json`:
- All deployed contract addresses
- `srcHash` for skip-if-unchanged logic
- Deployment timestamp

### Key Deployment Scripts

- `contracts/script/v3/DeployAnvil.s.sol` - Local deployment
- `contracts/script/v3/DeployLive.s.sol` - Testnet/mainnet deployment
- `contracts/script/v3/TestAccountPrepare.s.sol` - Test account setup
- `contracts/script/checks/` - Post-deployment verification scripts
- `contracts/script/deployment/` - Step-by-step individual deployments

---

## Security Considerations

### Access Control Patterns

- Use OpenZeppelin's `Ownable` for single-owner contracts
- Use custom role-based access for multi-role contracts (Registry)
- Always check `msg.sender` before state changes
- Use `nonReentrant` modifier for external calls with tokens

### Critical Security Rules

1. **Never commit private keys** - Use environment files (excluded in `.gitignore`)
2. **Verify all external calls** - Check return values and handle failures
3. **Use CEI pattern** - Checks-Effects-Interactions to prevent reentrancy
4. **Validate all inputs** - Check addresses are non-zero, amounts are valid
5. **Test access control** - Every privileged function must have access tests

### Slashing and Penalties

The system includes slashing mechanisms for:
- Malicious operators
- Invalid BLS signatures
- DVT consensus failures
- Reputation violations

### Upgrade Safety

- UUPS proxy pattern requires `upgradeToAndCall` with proper authorization
- Implementation contracts should have no state initialization in constructor
- Always verify new implementation before upgrading

### CI Security

`.github/workflows/check-secrets.yml` scans for:
- Ethereum private keys
- AWS credentials
- API keys (OpenAI, Google AI, Anthropic, GitHub, Stripe)
- PEM private keys

---

## Configuration and Utilities

### Foundry Configuration (foundry.toml)

```toml
[profile.default]
src = "contracts/src"
test = "contracts/test"
script = "script"
out = "out"
libs = ["contracts/lib", "singleton-paymaster/lib"]
solc_version = "0.8.33"
optimizer = true
optimizer_runs = 10000
via_ir = true
evm_version = "cancun"
```

### File System Permissions

The following paths have read-write permissions for Forge scripts:
- `./contracts/deployments`
- `./script`
- `./`
- `./script/v3`

### Helper Scripts

- `scripts/extract_v3_abis.sh` - Extract ABIs from build output
- `compare_abis.js` - Compare ABI versions
- `version-check-onchain.sh` - Verify on-chain contract versions

---

## Subgraph Indexing

The Graph configuration in `subgraph/`:
- `schema.graphql` - Entity definitions
- `subgraph.yaml` - Data source configuration
- `src/mapping.ts` - Event handlers (AssemblyScript)

Indexed entities:
- SBT (Soulbound Token)
- Community
- CommunityMembership
- Activity
- ReputationScore
- WeeklyActivityStat
- GlobalStat

---

## EntryPoint Addresses

- **v0.6**: `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789`
- **v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- **v0.8**: Same as v0.7

---

## Commit and Pull Request Guidelines

### Commit Messages

Use Conventional Commit style:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `test:` - Test additions/changes
- `refactor:` - Code refactoring
- `chore:` - Maintenance tasks

Examples:
- `feat(v4): add slashing mechanism to Registry`
- `fix(v3): correct price feed decimal handling`
- `docs: update deployment instructions`

### PR Requirements

1. Include a concise summary of changes
2. Note test execution status (or why tests were not run)
3. Document any deployment/config changes
4. If touching deployments, specify target network
5. Update relevant `deployments/config.<network>.json` if needed

---

## Troubleshooting

### Common Issues

**Build fails with "Stack too deep"**
- Enable `via_ir = true` in foundry.toml (already enabled)
- Use struct packing for function parameters

**Test fails with "EvmError: Revert"**
- Check `vm.expectRevert()` is properly used
- Verify prank addresses have proper permissions

**Deployment skipped unexpectedly**
- Check `srcHash` in deployment config
- Use `--force` flag to override

**Out of gas on deployment**
- Use `--via-ir` for better optimization
- Reduce optimizer runs if needed (currently 10000)

---

## External Resources

- **ERC-4337 Spec**: https://eips.ethereum.org/EIPS/eip-4337
- **Foundry Book**: https://book.getfoundry.sh/
- **OpenZeppelin Contracts**: https://docs.openzeppelin.com/contracts
- **Chainlink Docs**: https://docs.chain.link/
- **The Graph Docs**: https://thegraph.com/docs/
- **Echidna Docs**: https://github.com/crytic/echidna
