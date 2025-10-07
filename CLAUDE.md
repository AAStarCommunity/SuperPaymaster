# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

SuperPaymaster-Contract is a **smart paymaster routing system** that automatically selects the best available paymaster for ERC-4337 Account Abstraction transactions. Instead of inheriting from existing paymasters, it acts as an intelligent router that manages a pool of registered paymasters and routes user operations to the most suitable one based on competitive pricing.

### Core Value Proposition
- **For Users/dApps**: Single entry point with automatic optimal paymaster selection
- **For Paymasters**: Competitive marketplace to gain more transaction volume
- **For Ecosystem**: Efficient gas sponsorship through market-driven pricing

## Architecture

### Core Components

1. **SuperPaymasterV6.sol** - Router for EntryPoint v0.6
   - Routes UserOperation to optimal registered paymaster
   - Manages paymaster pool and selection algorithm

2. **SuperPaymasterV7.sol** - Router for EntryPoint v0.7
   - Routes PackedUserOperation to optimal registered paymaster
   - Enhanced gas limit parsing and simulation features

3. **SuperPaymasterV8.sol** - Router for EntryPoint v0.8 with EIP-7702 support
   - Extends V7 with EIP-7702 account delegation features
   - Future-ready for advanced account abstraction patterns

4. **BasePaymasterRouter.sol** - Shared routing logic
   - Common paymaster pool management
   - Fee rate competition and selection algorithms
   - Statistics tracking and reputation management

5. **IPaymasterRouter.sol** - Common interface
   - Standardized routing interface across all versions

### Key Architecture Patterns

- **Router Pattern**: SuperPaymaster acts as intelligent middleware, not as a paymaster itself
- **Competitive Marketplace**: Paymasters compete on fee rates (basis points) for transaction routing
- **Multi-Version Support**: Separate contracts for different EntryPoint versions (v0.6/v0.7/v0.8)
- **Simple Selection Algorithm**: V1 uses lowest fee rate priority (future versions can add reputation scoring)
- **Fail-Safe Routing**: Graceful handling of paymaster failures with automatic selection of alternatives
- **Statistics Tracking**: Success/failure rates for each registered paymaster

## Development Commands

### Build & Compilation
```bash
# Compile all contracts
forge build

# Format Solidity code
forge fmt
```

### Testing
```bash
# Run all tests
forge test

# Run tests with verbosity (show logs)
forge test -vvv

# Run specific test file
forge test --match-path test/Counter.t.sol

# Run specific test function
forge test --match-test test_Increment

# Gas snapshots for optimization
forge snapshot
```

### Development Environment
```bash
# Start local Ethereum node
anvil

# Deploy contracts (example)
forge script script/Counter.s.sol:CounterScript --rpc-url <RPC_URL> --private-key <PRIVATE_KEY>
```

### Dependencies
```bash
# Install npm dependencies (OpenZeppelin contracts)
npm install

# Update git submodules (Pimlico paymasters)
git submodule update --init --recursive
```

## Current Implementation Status

### Completed Features
- Paymaster registration with ENS verification
- ETH deposit/withdrawal management
- Basic bidding event emission
- Reputation tracking system

### Implementation Status

#### ✅ Completed V1 Features
- **Multi-Version Support**: Three separate routers (V6/V7/V8) for different EntryPoint versions
- **Paymaster Pool Management**: Registration, activation/deactivation, fee rate updates
- **Competitive Fee Structure**: Fee rates in basis points (100 = 1%)
- **Smart Routing Algorithm**: Automatic selection of lowest fee rate paymaster with availability checks
- **Statistics Tracking**: Success counts and total attempts per paymaster
- **EntryPoint Integration**: Full deposit/withdraw/stake management for each router
- **Emergency Controls**: Owner-only pause and removal functions
- **Simulation Features**: Preview paymaster selection without execution

#### 🔮 V2 Planned Features
- Enhanced reputation scoring (weighted by success rate and transaction volume)
- ENS integration for paymaster naming
- Router fee collection and revenue sharing
- Advanced selection algorithms (reputation + price optimization)
- Cross-version paymaster migration tools

## Testing Strategy

When adding new features:
1. **Version-Specific Tests**: Create tests for each EntryPoint version (V6/V7/V8)
2. **Router Testing**: Test paymaster selection algorithm, routing logic, and failure handling
3. **Integration Testing**: Test with actual paymaster implementations
4. **Gas Benchmarking**: Measure routing overhead compared to direct paymaster calls
5. **Edge Cases**: Test with no available paymasters, paymaster failures, and invalid operations

## Contract Dependencies

- **Account Abstraction Contracts**: EntryPoint interfaces for v0.6/v0.7/v0.8
- **OpenZeppelin Contracts v5.0.2**: Access control (Ownable) and reentrancy protection
- **Singleton Paymaster Interfaces**: For calling registered paymasters
- **Forge-std**: Testing framework and utilities

## Architecture Decision Records

### Why Router Pattern Instead of Inheritance?
1. **Separation of Concerns**: Routing logic separate from paymaster implementation
2. **Flexibility**: Can route to any paymaster implementation (not just Pimlico's)
3. **Scalability**: Can manage multiple paymasters without complex inheritance chains
4. **Simplicity**: Cleaner codebase with focused responsibilities

## Important Considerations

### Technical Requirements
- **Solidity Version**: ^0.8.26 (EntryPoint v0.8 requires ^0.8.28, so V8 uses V7 interfaces temporarily)
- **Gas Optimization**: Router adds minimal gas overhead to paymaster calls
- **EntryPoint Compatibility**: Each version only compatible with corresponding EntryPoint version

### Economic Model
- **Fee Structure**: Basis points system (100 = 1%, max 10000 = 100%)
- **Selection Algorithm**: V1 uses simple lowest fee rate (future versions will add reputation weighting)
- **Router Fees**: V1 has no router fees (can be enabled in future versions)

### Security Considerations
- **Paymaster Validation**: Router validates paymaster availability and balance before routing
- **Fail-Safe Design**: Router gracefully handles paymaster failures without breaking user operations
- **Owner Controls**: Emergency pause and paymaster removal functions
- **Reentrancy Protection**: All state-changing functions protected against reentrancy attacks