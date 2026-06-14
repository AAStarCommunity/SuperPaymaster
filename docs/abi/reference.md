<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with `pnpm gen:abi-docs` (scripts/gen-abi-docs.mjs).
     Source of truth: out/ compiled ABIs + NatSpec. Hand edits will be overwritten. -->

# SuperPaymaster — Generated ABI Reference

Authoritative, auto-generated reference for every external/public function, event, and error across the SuperPaymaster `src/` contracts. Generated from compiled `out/` artifacts (ABI + solc selectors + NatSpec). See [`README.md`](./README.md) for how this is produced and [`capabilities.md`](./capabilities.md) for a capability-grouped map.

> **Access control** is scraped best-effort from Solidity source modifiers (`onlyOwner`, `onlyEntryPoint`, …); `—` means no recognised access modifier was found on the declaration (it may still be guarded inside the body — verify against source).

## Contracts

- [GTokenStaking](#gtokenstaking) — `contracts/src/core/GTokenStaking.sol`
- [Registry](#registry) — `contracts/src/core/Registry.sol`
- [IERC1363Receiver](#ierc1363receiver) — `contracts/src/interfaces/IERC1363.sol`
- [IPaymasterRouter](#ipaymasterrouter) — `contracts/src/interfaces/IPaymasterRouter.sol`
- [ISBT](#isbt) — `contracts/src/interfaces/ISBT.sol`
- [ISuperPaymaster](#isuperpaymaster) — `contracts/src/interfaces/ISuperPaymaster.sol`
- [ISuperPaymasterRegistry](#isuperpaymasterregistry) — `contracts/src/interfaces/ISuperPaymasterRegistry.sol`
- [IVersioned](#iversioned) — `contracts/src/interfaces/IVersioned.sol`
- [IxPNTsFactory](#ixpntsfactory) — `contracts/src/interfaces/IxPNTsFactory.sol`
- [IxPNTsToken](#ixpntstoken) — `contracts/src/interfaces/IxPNTsToken.sol`
- [IAgentIdentityRegistry](#iagentidentityregistry) — `contracts/src/interfaces/v3/IAgentIdentityRegistry.sol`
- [IAgentReputationRegistry](#iagentreputationregistry) — `contracts/src/interfaces/v3/IAgentReputationRegistry.sol`
- [IBLSAggregator](#iblsaggregator) — `contracts/src/interfaces/v3/IBLSAggregator.sol`
- [IERC3009](#ierc3009) — `contracts/src/interfaces/v3/IERC3009.sol`
- [IGTokenStaking](#igtokenstaking) — `contracts/src/interfaces/v3/IGTokenStaking.sol`
- [IMySBT](#imysbt) — `contracts/src/interfaces/v3/IMySBT.sol`
- [IRegistry](#iregistry) — `contracts/src/interfaces/v3/IRegistry.sol`
- [IReputationCalculator](#ireputationcalculator) — `contracts/src/interfaces/v3/IReputationCalculator.sol`
- [ISignatureTransfer](#isignaturetransfer) — `contracts/src/interfaces/v3/ISignatureTransfer.sol`
- [MockAgentIdentityRegistry](#mockagentidentityregistry) — `contracts/src/mocks/MockAgentIdentityRegistry.sol`
- [MockAgentReputationRegistry](#mockagentreputationregistry) — `contracts/src/mocks/MockAgentReputationRegistry.sol`
- [MockBLSAggregator](#mockblsaggregator) — `contracts/src/mocks/MockBLSAggregator.sol`
- [MockUSDT](#mockusdt) — `contracts/src/mocks/MockUSDT.sol`
- [MyNFT](#mynft) — `contracts/src/mocks/MyNFT.sol`
- [TestSBT](#testsbt) — `contracts/src/mocks/TestSBT.sol`
- [BLSAggregator](#blsaggregator) — `contracts/src/modules/monitoring/BLSAggregator.sol`
- [IDVTValidator](#idvtvalidator) — `contracts/src/modules/monitoring/BLSAggregator.sol`
- [IRegistryStakingAwareBLS](#iregistrystakingawarebls) — `contracts/src/modules/monitoring/BLSAggregator.sol`
- [ISuperPaymasterSlash](#isuperpaymasterslash) — `contracts/src/modules/monitoring/BLSAggregator.sol`
- [DVTValidator](#dvtvalidator) — `contracts/src/modules/monitoring/DVTValidator.sol`
- [IRegistryStakingAware](#iregistrystakingaware) — `contracts/src/modules/monitoring/DVTValidator.sol`
- [ReputationSystem](#reputationsystem) — `contracts/src/modules/reputation/ReputationSystem.sol`
- [BasePaymasterUpgradeable](#basepaymasterupgradeable) — `contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol`
- [MicroPaymentChannel](#micropaymentchannel) — `contracts/src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol`
- [SuperPaymaster](#superpaymaster) — `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`
- [PaymasterFactory](#paymasterfactory) — `contracts/src/paymasters/v4/core/PaymasterFactory.sol`
- [Paymaster](#paymaster) — `contracts/src/paymasters/v4/Paymaster.sol`
- [IERC20Metadata](#ierc20metadata) — `contracts/src/paymasters/v4/PaymasterBase.sol`
- [PaymasterBase](#paymasterbase) — `contracts/src/paymasters/v4/PaymasterBase.sol`
- [GToken](#gtoken) — `contracts/src/tokens/GToken.sol`
- [GTokenAuthorization](#gtokenauthorization) — `contracts/src/tokens/GTokenAuthorization.sol`
- [MySBT](#mysbt) — `contracts/src/tokens/MySBT.sol`
- [xPNTsFactory](#xpntsfactory) — `contracts/src/tokens/xPNTsFactory.sol`
- [xPNTsToken](#xpntstoken) — `contracts/src/tokens/xPNTsToken.sol`
- [BLS](#bls) — `contracts/src/utils/BLS.sol`

## GTokenStaking

- **Source:** `contracts/src/core/GTokenStaking.sol`
- **Functions:** 29 · **Events:** 10 · **Errors:** 19
- **Title:** GTokenStaking v4.2.0 — Unified Ticket Model
- Unified Role-Based Staking with Ticket Model (transfer to treasury)

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xaed2d908` | `authorizedSlashers(address)` | view | — |  |
| `0xa0821be3` | `availableBalance(address)` | pure | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — | Get user's total staked balance |
| `0x7c50309f` | `getLockedStake(address,bytes32)` | view | — | Get locked stake amount for a role |
| `0xf50102c0` | `getStakeInfo(address,bytes32)` | view | — | Get operator's stake info for a role |
| `0x91b65cd6` | `getUserRoleLocks(address)` | view | — | Get all role locks for a user |
| `0x7f6b337b` | `GTOKEN()` | view | — |  |
| `0x6d265c11` | `hasRoleLock(address,bytes32)` | view | — | Check if user has lock for a role |
| `0x9e9093da` | `lockStakeWithTicket(address,bytes32,uint256,uint256,address)` | nonpayable | onlyRegistry, nonReentrant | Unified registration: handle ticket + optional stake for any role |
| `0x84747ba8` | `MAX_TOTAL_STAKE()` | view | — | Maximum total stake cap — equals GToken total supply (21M). GToken is a limited-issuance governance token (analogous to BTC's 21M cap). Using `constant` is intentional: the supply cap is a protocol invariant, not a tunable parameter. Adjusting it requires a full token economics redesign. |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0xb4d81fb3` | `previewExitFee(address,bytes32)` | view | — | Preview exit fee for a role |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x94e2b21e` | `roleExitConfigs(bytes32)` | view | — |  |
| `0x30b039ee` | `roleLocks(address,bytes32)` | view | — | Get role lock details |
| `0x36cb2b82` | `setAuthorizedSlasher(address,bool)` | nonpayable | onlyOwner | Set authorized slasher |
| `0xd64c66aa` | `setRoleExitFee(bytes32,uint256,uint256)` | nonpayable | — | Set exit fee configuration for a role |
| `0xf0f44260` | `setTreasury(address)` | nonpayable | onlyOwner | Set the protocol treasury address |
| `0x678b3ee2` | `slash(address,uint256,string)` | nonpayable | nonReentrant | Slash a user |
| `0x8f764848` | `slashByDVT(address,bytes32,uint256,string)` | nonpayable | nonReentrant | Slash operator's stake (DVT Validator only) |
| `0x16934fc4` | `stakes(address)` | view | — |  |
| `0x4bcb80a2` | `topUpStake(address,bytes32,uint256,address)` | nonpayable | onlyRegistry, nonReentrant | Top up stake for an existing role (Registry only) |
| `0x817b1cd2` | `totalStaked()` | view | — | Get total staked in protocol |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x61d027b3` | `treasury()` | view | — |  |
| `0x374e4d73` | `unlockAndTransfer(address,bytes32)` | nonpayable | onlyRegistry, nonReentrant | Unlock and transfer to user (Registry only) |
| `0x6da12d0c` | `userActiveRoles(address,uint256)` | view | — |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `authorizedSlashers(address arg0)`

`0xaed2d908` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `availableBalance(address arg0)`

`0xa0821be3` · pure · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `balanceOf(address user)`

`0x70a08231` · view · access: —

> Get user's total staked balance

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Total staked GToken value |

#### `getLockedStake(address user, bytes32 roleId)`

`0x7c50309f` · view · access: —

> Get locked stake amount for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Locked amount for this role |

#### `getStakeInfo(address operator, bytes32 roleId)`

`0xf50102c0` · view · access: —

> Get operator's stake info for a role

| param | type | description |
|---|---|---|
| `operator` | `address` | Operator address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `(uint256,uint256,uint256,uint256)` | Stake information (role-specific view) |

#### `getUserRoleLocks(address user)`

`0x91b65cd6` · view · access: —

> Get all role locks for a user

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `(uint128,uint128,uint48,bytes32,bytes)[]` | Array of role locks |

#### `GTOKEN()`

`0x7f6b337b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `hasRoleLock(address user, bytes32 roleId)`

`0x6d265c11` · view · access: —

> Check if user has lock for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if user has lock for this role |

#### `lockStakeWithTicket(address user, bytes32 roleId, uint256 stakeAmount, uint256 ticketPrice, address payer)`

`0x9e9093da` · nonpayable · access: onlyRegistry, nonReentrant

> Unified registration: handle ticket + optional stake for any role

*@dev* Transfers (stakeAmount + ticketPrice) from payer.      When stakeAmount=0: ticket-only, no lock created (for ENDUSER, COMMUNITY).      When stakeAmount>0: ticket to treasury + stake locked (for operators).

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |
| `stakeAmount` | `uint256` |  |
| `ticketPrice` | `uint256` |  |
| `payer` | `address` |  |

| returns | type | description |
|---|---|---|
| `lockId` | `uint256` |  |

#### `MAX_TOTAL_STAKE()`

`0x84747ba8` · view · access: —

> Maximum total stake cap — equals GToken total supply (21M). GToken is a limited-issuance governance token (analogous to BTC's 21M cap). Using `constant` is intentional: the supply cap is a protocol invariant, not a tunable parameter. Adjusting it requires a full token economics redesign.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `previewExitFee(address user, bytes32 roleId)`

`0xb4d81fb3` · view · access: —

> Preview exit fee for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role to exit |

| returns | type | description |
|---|---|---|
| `fee` | `uint256` | Exit fee amount |
| `netAmount` | `uint256` | Amount after fee |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `roleExitConfigs(bytes32 arg0)`

`0x94e2b21e` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `feePercent` | `uint256` |  |
| `minFee` | `uint256` |  |

#### `roleLocks(address arg0, bytes32 arg1)`

`0x30b039ee` · view · access: —

> Get role lock details

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `amount` | `uint128` |  |
| `ticketPrice` | `uint128` |  |
| `lockedAt` | `uint48` |  |
| `roleId` | `bytes32` |  |
| `metadata` | `bytes` |  |

#### `setAuthorizedSlasher(address slasher, bool authorized)`

`0x36cb2b82` · nonpayable · access: onlyOwner

> Set authorized slasher

| param | type | description |
|---|---|---|
| `slasher` | `address` | Address to authorize |
| `authorized` | `bool` | Authorization status |

#### `setRoleExitFee(bytes32 roleId, uint256 feePercent, uint256 minFee)`

`0xd64c66aa` · nonpayable · access: —

> Set exit fee configuration for a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |
| `feePercent` | `uint256` | Fee percentage (basis points) |
| `minFee` | `uint256` | Minimum fee amount |

#### `setTreasury(address _treasury)`

`0xf0f44260` · nonpayable · access: onlyOwner

> Set the protocol treasury address

| param | type | description |
|---|---|---|
| `_treasury` | `address` | New treasury address |

#### `slash(address user, uint256 amount, string reason)`

`0x678b3ee2` · nonpayable · access: nonReentrant

> Slash a user

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `amount` | `uint256` |  |
| `reason` | `string` |  |

| returns | type | description |
|---|---|---|
| `slashedAmount` | `uint256` |  |

#### `slashByDVT(address operator, bytes32 roleId, uint256 penaltyAmount, string reason)`

`0x8f764848` · nonpayable · access: nonReentrant

> Slash operator's stake (DVT Validator only)

| param | type | description |
|---|---|---|
| `operator` | `address` | Operator to slash |
| `roleId` | `bytes32` | Role being slashed |
| `penaltyAmount` | `uint256` | Amount of GToken to slash |
| `reason` | `string` | Reason for slashing |

#### `stakes(address arg0)`

`0x16934fc4` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `amount` | `uint256` |  |
| `slashedAmount` | `uint256` |  |
| `stakedAt` | `uint256` |  |
| `unstakeRequestedAt` | `uint256` |  |

#### `topUpStake(address user, bytes32 roleId, uint256 stakeAmount, address payer)`

`0x4bcb80a2` · nonpayable · access: onlyRegistry, nonReentrant

> Top up stake for an existing role (Registry only)

*@dev* Does NOT reset lockedAt time. Only increases amount.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |
| `stakeAmount` | `uint256` |  |
| `payer` | `address` |  |

#### `totalStaked()`

`0x817b1cd2` · view · access: —

> Get total staked in protocol

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `treasury()`

`0x61d027b3` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `unlockAndTransfer(address user, bytes32 roleId)`

`0x374e4d73` · nonpayable · access: onlyRegistry, nonReentrant

> Unlock and transfer to user (Registry only)

*@dev* OPERATORS ONLY — Regular user roles (ENDUSER, COMMUNITY) have no exit.      Registry enforces this by checking roleStakes before calling.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `netAmount` | `uint256` |  |

#### `userActiveRoles(address arg0, uint256 arg1)`

`0x6da12d0c` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xc80e6b66eb58558814d2cbd504bae3d3ed4eb316287800124c793081728599ad` | `RoleExitFeeUpdated(bytes32,uint256,uint256)` |
| `0xe0a56452e1e2337147f048c582bc931e7c341d221b44961f32dec8b73fd669bc` | `SlasherAuthorizationUpdated(address,bool)` |
| `0xe4c76dcad70ec0bf6b921afbe6bb7b4950aedf705245ec68942ea9ecf00f8a0c` | `StakeLocked(address,bytes32,uint256,uint256,uint256)` |
| `0x2ddf1fb64780154d8eb9ffdc751b1274b45fd5803186217b514fd91e6ae3b1a7` | `StakeSlashed(address,bytes32,uint256,string,uint256)` |
| `0x9cadbc33680e22a2f04ed8eb0d7cc7f218ee9231b3473ed05904c7ec5e2d483d` | `StakeUnlocked(address,bytes32,uint256,uint256,uint256,uint256)` |
| `0xb095d4d7990b498e886fe544495d08fafb40e2675fd41d78e8abf3778ebcada4` | `SyncFailed(address,bytes)` |
| `0xfd8455407fc2a5f2a6f1ea576385d9201fe1b9bd1b3ecb8bdab57d320cfbb475` | `TicketBurned(address,bytes32,uint256,address)` |
| `0x4ab5be82436d353e61ca18726e984e561f5c1cc7c6d38b29d2553c790434705a` | `TreasuryUpdated(address,address)` |
| `0x6951689eba99e77d7e3b622f276c0ad8e36126c3c510f181b86d05d685eaa074` | `UserSlashed(address,uint256,string,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0xcd786059` | `AddressInsufficientBalance(address)` |
| `0x54ada055` | `AmountExceedsUint128()` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0xcd4e6167` | `FeeTooHigh()` |
| `0xf1bc94d2` | `InsufficientStake()` |
| `0xe6c4247b` | `InvalidAddress()` |
| `0xf90e998d` | `NoLockFound()` |
| `0xa4bc77a7` | `NotAuthorizedSlasher()` |
| `0x87aa01c8` | `OnlyRegistry()` |
| `0x70f2db9a` | `OnlyRegistryOrAuthorized()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0xe4a49d58` | `RoleAlreadyLocked()` |
| `0x8a988b12` | `RoleNotLocked()` |
| `0x5274afe7` | `SafeERC20FailedOperation(address)` |
| `0x03a16256` | `TotalStakeExceedsCap()` |
| `0x82b42900` | `Unauthorized()` |

## Registry

- **Source:** `contracts/src/core/Registry.sol`
- **Functions:** 42 · **Events:** 18 · **Errors:** 33

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x1b02e44f` | `batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)` | nonpayable | nonReentrant | Batch update global reputation |
| `0xe20bce2e` | `blacklistNonce()` | view | — | Monotonic nonce for blacklist BLS proofs (P0-3 replay protection). |
| `0xbe30742f` | `blsAggregator()` | view | — |  |
| `0x5ee05b17` | `configureRole(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256))` | nonpayable | nonReentrant | Configure or create a role |
| `0xaf5eda02` | `creditTierConfig(uint256)` | view | — |  |
| `0x727b52a5` | `exitRole(bytes32)` | nonpayable | nonReentrant | Exit from a role |
| `0xb1988995` | `getCommunityByENS(string)` | view | — |  |
| `0x64c39a43` | `getCommunityByName(string)` | view | — |  |
| `0x2c333e25` | `getCreditLimit(address)` | view | — | Get credit limit for user based on reputation |
| `0x913e6779` | `getEffectiveStake(address,bytes32)` | view | — | Effective per-role stake from Staking source of truth (P0-14). |
| `0xb5e936ab` | `getRoleConfig(bytes32)` | view | — | Get role configuration |
| `0x3cd01548` | `getRoleStake(bytes32,address)` | view | — |  |
| `0x4b8b8a6e` | `getRoleUserCount(bytes32)` | view | — | Get total users with a specific role |
| `0x06a36aee` | `getUserRoles(address)` | view | — | Get all roles for a user |
| `0x11c85b0b` | `globalReputation(address)` | view | — |  |
| `0x826600ce` | `GTOKEN_STAKING()` | view | — |  |
| `0x91d14854` | `hasRole(bytes32,address)` | view | — | Check if user has a specific role |
| `0xc0c53b8b` | `initialize(address,address,address)` | nonpayable | initializer |  |
| `0xbf28c98a` | `isReputationSource(address)` | view | — |  |
| `0x5c445412` | `levelThresholds(uint256)` | view | — |  |
| `0x424a3d77` | `markProposalExecuted(uint256)` | nonpayable | — | Mark a BLS proposal as executed (called by BLSAggregator for slash-only proposals) |
| `0x19c46e81` | `MYSBT()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x52d1902d` | `proxiableUUID()` | view | — |  |
| `0x669d7762` | `registerRole(bytes32,address,bytes)` | nonpayable | nonReentrant | Register a user for a specific role (unified API) |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x17e1c595` | `safeMintForRole(bytes32,address,bytes)` | nonpayable | nonReentrant |  |
| `0xbc959101` | `setBLSAggregator(address)` | nonpayable | onlyOwner |  |
| `0x15de32ca` | `setCreditTier(uint256,uint256)` | nonpayable | onlyOwner | Configure credit limit for a level |
| `0xbb2ae6bf` | `setLevelThresholds(uint256[])` | nonpayable | onlyOwner |  |
| `0xcd5d1e74` | `setMySBT(address)` | nonpayable | onlyOwner |  |
| `0x6229738c` | `setReputationSource(address,bool)` | nonpayable | onlyOwner |  |
| `0x8ff39099` | `setStaking(address)` | nonpayable | onlyOwner | Update the GTokenStaking contract pointer. Auto-syncs all exit fees. |
| `0xe79e9739` | `setSuperPaymaster(address)` | nonpayable | onlyOwner |  |
| `0x919d1e2c` | `SUPER_PAYMASTER()` | view | — |  |
| `0xbb8ca259` | `syncExitFees(bytes32[])` | nonpayable | onlyOwner | Admin-triggered batch sync. Emits SyncFailed for any role whose         call to staking reverts — indexers watch this topic for alerting. |
| `0x7d960e37` | `syncStakeFromStaking(address,bytes32,uint256)` | nonpayable | — | Push a fresh stake snapshot from Staking into Registry's per-role cache. |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0xce830e7b` | `updateOperatorBlacklist(address,address[],bool[],bytes)` | nonpayable | nonReentrant | Update operator blacklist (via DVT consensus) |
| `0xad3cb1cc` | `UPGRADE_INTERFACE_VERSION()` | view | — |  |
| `0x4f1ef286` | `upgradeToAndCall(address,bytes)` | payable | — |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `batchUpdateGlobalReputation(uint256 proposalId, address[] users, uint256[] newScores, uint256 epoch, bytes proof)`

`0x1b02e44f` · nonpayable · access: nonReentrant

> Batch update global reputation

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |
| `users` | `address[]` | Users to update |
| `newScores` | `uint256[]` | New scores |
| `epoch` | `uint256` | Update epoch |
| `proof` | `bytes` | DVT signature proof |

#### `blacklistNonce()`

`0xe20bce2e` · view · access: —

> Monotonic nonce for blacklist BLS proofs (P0-3 replay protection).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `blsAggregator()`

`0xbe30742f` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `configureRole(bytes32 roleId, (uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256) config)`

`0x5ee05b17` · nonpayable · access: nonReentrant

> Configure or create a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role to configure |
| `config` | `(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256)` | New configuration (must include owner) |

#### `creditTierConfig(uint256 arg0)`

`0xaf5eda02` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `exitRole(bytes32 roleId)`

`0x727b52a5` · nonpayable · access: nonReentrant

> Exit from a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role to exit from |

#### `getCommunityByENS(string ensName)`

`0xb1988995` · view · access: —

| param | type | description |
|---|---|---|
| `ensName` | `string` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getCommunityByName(string name)`

`0x64c39a43` · view · access: —

| param | type | description |
|---|---|---|
| `name` | `string` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getCreditLimit(address user)`

`0x2c333e25` · view · access: —

> Get credit limit for user based on reputation

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Credit limit in aPNTs (18 decimals) |

#### `getEffectiveStake(address user, bytes32 roleId)`

`0x913e6779` · view · access: —

> Effective per-role stake from Staking source of truth (P0-14).

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getRoleConfig(bytes32 roleId)`

`0xb5e936ab` · view · access: —

> Get role configuration

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256)` | Role configuration |

#### `getRoleStake(bytes32 roleId, address user)`

`0x3cd01548` · view · access: —

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` |  |
| `user` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getRoleUserCount(bytes32 roleId)`

`0x4b8b8a6e` · view · access: —

> Get total users with a specific role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Total count |

#### `getUserRoles(address user)`

`0x06a36aee` · view · access: —

> Get all roles for a user

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `bytes32[]` | Array of role IDs |

#### `globalReputation(address arg0)`

`0x11c85b0b` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `GTOKEN_STAKING()`

`0x826600ce` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `hasRole(bytes32 arg0, address arg1)`

`0x91d14854` · view · access: —

> Check if user has a specific role

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `initialize(address _owner, address _gtokenStaking, address _mysbt)`

`0xc0c53b8b` · nonpayable · access: initializer

| param | type | description |
|---|---|---|
| `_owner` | `address` |  |
| `_gtokenStaking` | `address` |  |
| `_mysbt` | `address` |  |

#### `isReputationSource(address arg0)`

`0xbf28c98a` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `levelThresholds(uint256 arg0)`

`0x5c445412` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `markProposalExecuted(uint256 proposalId)`

`0x424a3d77` · nonpayable · access: —

> Mark a BLS proposal as executed (called by BLSAggregator for slash-only proposals)

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |

#### `MYSBT()`

`0x19c46e81` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `proxiableUUID()`

`0x52d1902d` · view · access: —

*@dev* Implementation of the ERC1822 {proxiableUUID} function. This returns the storage slot used by the implementation. It is used to validate the implementation's compatibility when performing an upgrade. IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `registerRole(bytes32 roleId, address user, bytes roleData)`

`0x669d7762` · nonpayable · access: nonReentrant

> Register a user for a specific role (unified API)

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier (e.g., ROLE_COMMUNITY, ROLE_PAYMASTER) |
| `user` | `address` | User address to register |
| `roleData` | `bytes` | Encoded role-specific data |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `safeMintForRole(bytes32 roleId, address user, bytes data)`

`0x17e1c595` · nonpayable · access: nonReentrant

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` |  |
| `user` | `address` |  |
| `data` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

#### `setBLSAggregator(address _aggregator)`

`0xbc959101` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_aggregator` | `address` |  |

#### `setCreditTier(uint256 level, uint256 limit)`

`0x15de32ca` · nonpayable · access: onlyOwner

> Configure credit limit for a level

| param | type | description |
|---|---|---|
| `level` | `uint256` |  |
| `limit` | `uint256` |  |

#### `setLevelThresholds(uint256[] thresholds)`

`0xbb2ae6bf` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `thresholds` | `uint256[]` |  |

#### `setMySBT(address _mysbt)`

`0xcd5d1e74` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_mysbt` | `address` |  |

#### `setReputationSource(address source, bool active)`

`0x6229738c` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `source` | `address` |  |
| `active` | `bool` |  |

#### `setStaking(address _staking)`

`0x8ff39099` · nonpayable · access: onlyOwner

> Update the GTokenStaking contract pointer. Auto-syncs all exit fees.

| param | type | description |
|---|---|---|
| `_staking` | `address` |  |

#### `setSuperPaymaster(address _sp)`

`0xe79e9739` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_sp` | `address` |  |

#### `SUPER_PAYMASTER()`

`0x919d1e2c` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `syncExitFees(bytes32[] roles)`

`0xbb8ca259` · nonpayable · access: onlyOwner

> Admin-triggered batch sync. Emits SyncFailed for any role whose         call to staking reverts — indexers watch this topic for alerting.

| param | type | description |
|---|---|---|
| `roles` | `bytes32[]` |  |

#### `syncStakeFromStaking(address user, bytes32 roleId, uint256 newAmount)`

`0x7d960e37` · nonpayable · access: —

> Push a fresh stake snapshot from Staking into Registry's per-role cache.

*@dev* Only callable by GTOKEN_STAKING (P0-14).

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |
| `newAmount` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `updateOperatorBlacklist(address operator, address[] users, bool[] statuses, bytes proof)`

`0xce830e7b` · nonpayable · access: nonReentrant

> Update operator blacklist (via DVT consensus)

*@dev* Forwards the update to SuperPaymaster

| param | type | description |
|---|---|---|
| `operator` | `address` | The operator/community address |
| `users` | `address[]` | List of users to update |
| `statuses` | `bool[]` | Blocked status (true = blocked) |
| `proof` | `bytes` | DVT signature proof |

#### `UPGRADE_INTERFACE_VERSION()`

`0xad3cb1cc` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `upgradeToAndCall(address newImplementation, bytes data)`

`0x4f1ef286` · payable · access: —

*@dev* Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call encoded in `data`. Calls {_authorizeUpgrade}. Emits an {Upgraded} event.

| param | type | description |
|---|---|---|
| `newImplementation` | `address` |  |
| `data` | `bytes` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x019f532f6e08ee8944dc2e7ac40f3c97ad4a20618aee847ddf7c502821c7dad4` | `BLSAggregatorUpdated(address,address)` |
| `0xe80f99d9789e367c229c526d3d3f84d44d3daf77ea65f7bbe8510f176ac45a23` | `BurnExecuted(address,bytes32,uint256,string)` |
| `0x7e684e0b76ed13bc9cf7e4fbac7d11873036be9c9a83f9958382721eeda46010` | `CreditTierUpdated(uint256,uint256)` |
| `0xbb42fde0252fd03324102c3666f457311508c4dd05f96e66e0fd26f0c28e8542` | `GlobalReputationUpdated(address,uint256,uint256)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0x171f7dbde35aed7cddf3ece2dad8f4eb62443a3d6bf8616586da6fd03c6b4ed9` | `MySBTContractUpdated(address,address)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x6be30291a8f228c9342613e5e66df1a1b85aa570ac1bca9219f3ac7b7f73bbf3` | `ReputationSourceUpdated(address,bool)` |
| `0x287e005099116032e1bba9482a5b0df09cc99f7e82a4482fa2810c52158d473d` | `RoleConfigured(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256),uint256)` |
| `0x0d9361411a652b66cd4aed24a96d36c0b048899896c927d879a9d3ba2790d9c6` | `RoleExited(bytes32,address,uint256,uint256)` |
| `0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d` | `RoleGranted(bytes32,address,address)` |
| `0x2c48d754bbf59f20e71c13710fac35aa1ea020da58dcbb366de0ef7f75c9377d` | `RoleRegistered(bytes32,address,uint256,uint256)` |
| `0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b` | `RoleRevoked(bytes32,address,address)` |
| `0xf6da96ea84a034d6f30b7b377637742735f36f14cfda9144397e4f1e69116f4a` | `SBTBurnFailed(address,bytes32)` |
| `0x7042586b23181180eb30b4798702d7a0233b7fc2551e89806770e8e5d9392e6a` | `StakingContractUpdated(address,address)` |
| `0x1f7cd67c986d0cce4aa6f69075b5278a05438ef2a5d1abf6eeded51ba8123245` | `SuperPaymasterUpdated(address,address)` |
| `0x3e9fc4a04e1f2759edf7001e63923124a42c59aef874442b88cdb30685c8833e` | `SyncFailed(address,bytes32)` |
| `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b` | `Upgraded(address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0x0b7d62e2` | `BatchTooLarge()` |
| `0xeeee2fe1` | `BLSFailed()` |
| `0x85bbf36e` | `BLSNotConfigured()` |
| `0xab338f96` | `BLSProofRequired()` |
| `0x1e82e519` | `CallerNotCommunity()` |
| `0x4c9c8ce3` | `ERC1967InvalidImplementation(address)` |
| `0xb398979f` | `ERC1967NonPayable()` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0xcd4e6167` | `FeeTooHigh()` |
| `0x112f598a` | `InsufficientConsensus()` |
| `0x45be0a26` | `InsufficientStake(uint256,uint256)` |
| `0xe481c269` | `InvalidAddr()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0xd2529034` | `InvalidParam()` |
| `0x0992f7ad` | `InvalidProposalId()` |
| `0x8b140a81` | `LenMismatch()` |
| `0x297876b6` | `LockNotMet()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x51618d53` | `ProposalAlreadyExecuted()` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x6dd4f06c` | `RoleAlreadyGranted(bytes32,address)` |
| `0x2b30318e` | `RoleNotConfigured(bytes32,bool)` |
| `0xe9007bcc` | `RoleNotGranted(bytes32,address)` |
| `0xcf8d29eb` | `SPNotSet()` |
| `0xe685a9c6` | `ThreshNotAscending()` |
| `0x3294781e` | `TooManyLevels()` |
| `0x82b42900` | `Unauthorized()` |
| `0x5cfb0e7f` | `UnauthorizedSource()` |
| `0xe07c8dba` | `UUPSUnauthorizedCallContext()` |
| `0xaa1d49a4` | `UUPSUnsupportedProxiableUUID(bytes32)` |

## IERC1363Receiver

- **Source:** `contracts/src/interfaces/IERC1363.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x88a7ca5c` | `onTransferReceived(address,address,uint256,bytes)` | nonpayable | — | Handle the receipt of ERC1363 tokens |

### Functions

#### `onTransferReceived(address operator, address from, uint256 value, bytes data)`

`0x88a7ca5c` · nonpayable · access: —

> Handle the receipt of ERC1363 tokens

| param | type | description |
|---|---|---|
| `operator` | `address` | address The address which called `transferAndCall` or `transferFromAndCall` function |
| `from` | `address` | address The address which are token transferred from |
| `value` | `uint256` | uint256 The amount of tokens transferred |
| `data` | `bytes` | bytes Additional data with no specified format |

| returns | type | description |
|---|---|---|
| `_0` | `bytes4` | bytes4 `bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"))` |

## IPaymasterRouter

- **Source:** `contracts/src/interfaces/IPaymasterRouter.sol`
- **Functions:** 8 · **Events:** 5 · **Errors:** 0
- **Title:** IPaymasterRouter
- Interface for paymaster routing functionality

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x007648de` | `getActivePaymasters()` | view | — | Get all active paymasters |
| `0xb42ba468` | `getBestPaymaster()` | view | — | Get the best available paymaster |
| `0x14b1c401` | `getPaymasterCount()` | view | — | Get total number of registered paymasters |
| `0xdc2a1472` | `getPaymasterInfo(address)` | view | — | Get paymaster information |
| `0x1afda978` | `registerPaymaster(address,uint256,string)` | nonpayable | — | Register a paymaster in the router |
| `0x05072850` | `setPaymasterStatus(address,bool)` | nonpayable | — | Activate/deactivate a paymaster (only owner) |
| `0x7b84fda5` | `updateFeeRate(uint256)` | nonpayable | — | Update fee rate for registered paymaster |
| `0xc7eb709b` | `updateStats(address,bool)` | nonpayable | — | Update routing statistics (internal use) |

### Functions

#### `getActivePaymasters()`

`0x007648de` · view · access: —

> Get all active paymasters

| returns | type | description |
|---|---|---|
| `paymasters` | `address[]` | Array of active paymaster addresses |

#### `getBestPaymaster()`

`0xb42ba468` · view · access: —

> Get the best available paymaster

| returns | type | description |
|---|---|---|
| `paymaster` | `address` | Address of the selected paymaster |
| `feeRate` | `uint256` | Fee rate of the selected paymaster |

#### `getPaymasterCount()`

`0x14b1c401` · view · access: —

> Get total number of registered paymasters

| returns | type | description |
|---|---|---|
| `count` | `uint256` | Total paymaster count |

#### `getPaymasterInfo(address _paymaster)`

`0xdc2a1472` · view · access: —

> Get paymaster information

| param | type | description |
|---|---|---|
| `_paymaster` | `address` | Address of the paymaster |

| returns | type | description |
|---|---|---|
| `pool` | `(address,uint256,bool,uint256,uint256,string)` | PaymasterPool struct with all information |

#### `registerPaymaster(address _paymaster, uint256 _feeRate, string _name)`

`0x1afda978` · nonpayable · access: —

> Register a paymaster in the router

| param | type | description |
|---|---|---|
| `_paymaster` | `address` | Address of the paymaster contract |
| `_feeRate` | `uint256` | Fee rate in basis points (100 = 1%) |
| `_name` | `string` | Display name for the paymaster |

#### `setPaymasterStatus(address _paymaster, bool _isActive)`

`0x05072850` · nonpayable · access: —

> Activate/deactivate a paymaster (only owner)

| param | type | description |
|---|---|---|
| `_paymaster` | `address` | Address of the paymaster |
| `_isActive` | `bool` | New active status |

#### `updateFeeRate(uint256 _newFeeRate)`

`0x7b84fda5` · nonpayable · access: —

> Update fee rate for registered paymaster

| param | type | description |
|---|---|---|
| `_newFeeRate` | `uint256` | New fee rate in basis points |

#### `updateStats(address _paymaster, bool _success)`

`0xc7eb709b` · nonpayable · access: —

> Update routing statistics (internal use)

| param | type | description |
|---|---|---|
| `_paymaster` | `address` | Address of the paymaster |
| `_success` | `bool` | Whether the routing was successful |

### Events

| topic0 | event |
|---|---|
| `0x41987a4dd100e0dea1147b3834730a8a9862a99c887bda5c606ff0b85dfc41eb` | `FeeRateUpdated(address,uint256,uint256)` |
| `0xdf816d1519fa8ef337a5ae6de9cf6c0d5914d9867cd2d29e0ceb6e795fcb838e` | `PaymasterRegistered(address,uint256,string)` |
| `0x2bb25ee6feed416bd775d0af32e6acbe917ef30a582d223f7ffe4e9fc0eb25e5` | `PaymasterSelected(address,address,uint256)` |
| `0x70f3008dcbe7ca1157c0809d9b79a5751736957d08f23274121a0903a38cfa99` | `PaymasterStatusChanged(address,bool)` |
| `0x80140d6bcee83a25999242a95412ea6b9754c623fc171e8d4c86c8392c053ad9` | `StatsUpdated(address,uint256,uint256)` |

## ISBT

- **Source:** `contracts/src/interfaces/ISBT.sol`
- **Functions:** 3 · **Events:** 0 · **Errors:** 0
- **Title:** ISBT - Soul-Bound Token Interface
- Interface for checking SBT (non-transferable NFT) ownership

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x70a08231` | `balanceOf(address)` | view | — | Check if an address holds at least one SBT |
| `0x4f558e79` | `exists(uint256)` | view | — | Check if a token exists (optional) |
| `0x6352211e` | `ownerOf(uint256)` | view | — | Get the owner of a specific token ID (optional, for ERC721 compatibility) |

### Functions

#### `balanceOf(address account)`

`0x70a08231` · view · access: —

> Check if an address holds at least one SBT

*@dev* For SBTs, this should typically return 0 or 1

| param | type | description |
|---|---|---|
| `account` | `address` | Address to check |

| returns | type | description |
|---|---|---|
| `balance` | `uint256` | Number of SBTs held by the account |

#### `exists(uint256 tokenId)`

`0x4f558e79` · view · access: —

> Check if a token exists (optional)

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` | The token ID to check |

| returns | type | description |
|---|---|---|
| `exists` | `bool` | True if token exists |

#### `ownerOf(uint256 tokenId)`

`0x6352211e` · view · access: —

> Get the owner of a specific token ID (optional, for ERC721 compatibility)

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` | The token ID to query |

| returns | type | description |
|---|---|---|
| `owner` | `address` | Address of the token owner |

## ISuperPaymaster

- **Source:** `contracts/src/interfaces/ISuperPaymaster.sol`
- **Functions:** 13 · **Events:** 7 · **Errors:** 0
- **Title:** ISuperPaymaster - Multi-tenant SuperPaymaster Interface
- Interface for SuperPaymaster V3 with per-operator configuration

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x5c7c4b5f` | `configureOperator(address,address)` | nonpayable | — | Configure operator billing settings.         Exchange rate is read from the xPNTs token contract at runtime. |
| `0xb6b55f25` | `deposit(uint256)` | nonpayable | — | Deposit aPNTs as gas collateral |
| `0x2f4f21e2` | `depositFor(address,uint256)` | nonpayable | — | Notify contract of a direct transfer (Ad-hoc Push Mode) |
| `0x079d2d42` | `executeSlashWithBLS(address,uint8,bytes)` | nonpayable | — | Slash operator via BLS consensus |
| `0xeafe74b5` | `getAvailableCredit(address,address)` | view | — | Get operator credit limit for a user |
| `0x6a16e22d` | `isEligibleForSponsorship(address)` | view | — |  |
| `0x13e7c9d8` | `operators(address)` | view | — | Get operator configuration |
| `0xf3a729da` | `settleX402Payment(address,address,address,uint256,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | — |  |
| `0x7344209c` | `settleX402PaymentDirect(address,address,address,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | — |  |
| `0x5f4cd4fe` | `updateBlockedStatus(address,address[],bool[])` | nonpayable | — |  |
| `0xa3970ae6` | `updateSBTStatus(address,bool)` | nonpayable | — |  |
| `0x54fd4d50` | `version()` | view | — | Get human-readable version string |
| `0x2e1a7d4d` | `withdraw(uint256)` | nonpayable | — | Withdraw aPNTs collateral |

### Functions

#### `configureOperator(address xPNTsToken, address _opTreasury)`

`0x5c7c4b5f` · nonpayable · access: —

> Configure operator billing settings.         Exchange rate is read from the xPNTs token contract at runtime.

| param | type | description |
|---|---|---|
| `xPNTsToken` | `address` |  |
| `_opTreasury` | `address` |  |

#### `deposit(uint256 amount)`

`0xb6b55f25` · nonpayable · access: —

> Deposit aPNTs as gas collateral

| param | type | description |
|---|---|---|
| `amount` | `uint256` |  |

#### `depositFor(address targetOperator, uint256 amount)`

`0x2f4f21e2` · nonpayable · access: —

> Notify contract of a direct transfer (Ad-hoc Push Mode)

| param | type | description |
|---|---|---|
| `targetOperator` | `address` |  |
| `amount` | `uint256` |  |

#### `executeSlashWithBLS(address operator, uint8 level, bytes proof)`

`0x079d2d42` · nonpayable · access: —

> Slash operator via BLS consensus

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `level` | `uint8` |  |
| `proof` | `bytes` |  |

#### `getAvailableCredit(address user, address token)`

`0xeafe74b5` · view · access: —

> Get operator credit limit for a user

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `token` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `isEligibleForSponsorship(address user)`

`0x6a16e22d` · view · access: —

| param | type | description |
|---|---|---|
| `user` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `operators(address operator)`

`0x13e7c9d8` · view · access: —

> Get operator configuration

| param | type | description |
|---|---|---|
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `aPNTsBalance` | `uint128` |  |
| `isConfigured` | `bool` |  |
| `isPaused` | `bool` |  |
| `xPNTsToken` | `address` |  |
| `reputation` | `uint32` |  |
| `minTxInterval` | `uint48` |  |
| `treasury` | `address` |  |
| `totalSpent` | `uint256` |  |
| `totalTxSponsored` | `uint256` |  |

#### `settleX402Payment(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validAfter, uint256 validBefore, bytes32 salt, bytes signature)`

`0xf3a729da` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `asset` | `address` |  |
| `amount` | `uint256` |  |
| `maxFee` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `salt` | `bytes32` |  |
| `signature` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `settlementId` | `bytes32` |  |

#### `settleX402PaymentDirect(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes signature)`

`0x7344209c` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `asset` | `address` |  |
| `amount` | `uint256` |  |
| `maxFee` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `signature` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `settlementId` | `bytes32` |  |

#### `updateBlockedStatus(address operator, address[] users, bool[] statuses)`

`0x5f4cd4fe` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `users` | `address[]` |  |
| `statuses` | `bool[]` |  |

#### `updateSBTStatus(address user, bool status)`

`0xa3970ae6` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `status` | `bool` |  |

#### `version()`

`0x54fd4d50` · view · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

#### `withdraw(uint256 amount)`

`0x2e1a7d4d` · nonpayable · access: —

> Withdraw aPNTs collateral

| param | type | description |
|---|---|---|
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0x823c9466affb5a8646bc5f7e6304f72a4622cc01af819ec2f51b1130a725c6d1` | `OperatorConfigured(address,address,address)` |
| `0x06653c045d0a3144153a51ac6909baae43b8d5b67184cb74e988b72858727fe4` | `OperatorDeposited(address,uint256)` |
| `0xa7503227727e36abb7f0ecf24f626347ccc20233c48c554d49d7d2077a1a3040` | `OperatorSlashed(address,uint256,uint8)` |
| `0x4eea589c35918e3c4d8e0371a062a1d544e41d78fb522381678923b9cd6e6dfa` | `OperatorWithdrawn(address,uint256)` |
| `0xfc577563f1b9a0461e24abef1e1fcc0d33d3d881f20b5df6dda59de4aae2c821` | `ReputationUpdated(address,uint256)` |
| `0xcde7e91a718e2439d8ff2a679ad52713e82a37b72622fb530c8c41039fdd5bf0` | `TransactionSponsored(address,address,uint256,uint256)` |
| `0xecef7698217b345db7161a8d2ffa4e7109c3ca0fe6e64ca6627ee67be3e818fc` | `X402PaymentSettled(address,address,address,uint256,uint256,bytes32)` |

## ISuperPaymasterRegistry

- **Source:** `contracts/src/interfaces/ISuperPaymasterRegistry.sol`
- **Functions:** 7 · **Events:** 0 · **Errors:** 0
- **Title:** ISuperPaymasterRegistry - SuperPaymaster Registry Interface
- Interface for checking if a Paymaster is registered in SuperPaymaster

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x0f15f4c0` | `activate()` | nonpayable | — | Activate the caller's paymaster |
| `0x51b42b00` | `deactivate()` | nonpayable | — | Deactivate the caller's paymaster |
| `0x007648de` | `getActivePaymasters()` | view | — | Get list of active paymasters |
| `0xb42ba468` | `getBestPaymaster()` | view | — | Get the best available paymaster based on fee rate |
| `0xdc2a1472` | `getPaymasterInfo(address)` | view | — | Get paymaster information |
| `0xd146de40` | `getRouterStats()` | view | — | Get router statistics |
| `0x92870822` | `isPaymasterActive(address)` | view | — | Check if a paymaster is registered and active |

### Functions

#### `activate()`

`0x0f15f4c0` · nonpayable · access: —

> Activate the caller's paymaster

*@dev* Only callable by registered paymaster, sets isActive to trueActivation requires passing Registry's qualification checks

#### `deactivate()`

`0x51b42b00` · nonpayable · access: —

> Deactivate the caller's paymaster

*@dev* Only callable by registered paymaster, sets isActive to falseDeactivate means: stop accepting new requests, but continue settlement & unstake

#### `getActivePaymasters()`

`0x007648de` · view · access: —

> Get list of active paymasters

| returns | type | description |
|---|---|---|
| `activePaymasters` | `address[]` | Array of active paymaster addresses |

#### `getBestPaymaster()`

`0xb42ba468` · view · access: —

> Get the best available paymaster based on fee rate

| returns | type | description |
|---|---|---|
| `paymaster` | `address` | Address of the best paymaster |
| `feeRate` | `uint256` | Fee rate of the selected paymaster |

#### `getPaymasterInfo(address paymaster)`

`0xdc2a1472` · view · access: —

> Get paymaster information

| param | type | description |
|---|---|---|
| `paymaster` | `address` | Address of the paymaster to query |

| returns | type | description |
|---|---|---|
| `feeRate` | `uint256` | Fee rate in basis points (100 = 1%) |
| `isActive` | `bool` | Whether the paymaster is active |
| `successCount` | `uint256` | Number of successful operations |
| `totalAttempts` | `uint256` | Total number of attempts |
| `name` | `string` | Display name |

#### `getRouterStats()`

`0xd146de40` · view · access: —

> Get router statistics

| returns | type | description |
|---|---|---|
| `totalPaymasters` | `uint256` | Total number of registered paymasters |
| `activePaymasters` | `uint256` | Number of active paymasters |
| `totalSuccessfulRoutes` | `uint256` | Total successful routes |
| `totalRoutes` | `uint256` | Total route attempts |

#### `isPaymasterActive(address paymaster)`

`0x92870822` · view · access: —

> Check if a paymaster is registered and active

| param | type | description |
|---|---|---|
| `paymaster` | `address` | Address to check |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if registered and active |

## IVersioned

- **Source:** `contracts/src/interfaces/IVersioned.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0
- **Title:** IVersioned
- Interface for contracts with version tracking

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x54fd4d50` | `version()` | view | — | Get human-readable version string |

### Functions

#### `version()`

`0x54fd4d50` · view · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

## IxPNTsFactory

- **Source:** `contracts/src/interfaces/IxPNTsFactory.sol`
- **Functions:** 4 · **Events:** 0 · **Errors:** 0
- **Title:** IxPNTsFactory
- Interface for xPNTsFactory contract

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x59734e1a` | `getAPNTsPrice()` | view | — | Get current aPNTs USD price |
| `0xb8d7b669` | `getTokenAddress(address)` | view | — | Get xPNTs token address for community |
| `0x9bb0f599` | `hasToken(address)` | view | — | Check if community has deployed token |
| `0x96e28d28` | `isXPNTs(address)` | view | — | Check if `token` was deployed via this factory and is therefore         a trusted xPNTs token (subject to firewall + per-tx caps). |

### Functions

#### `getAPNTsPrice()`

`0x59734e1a` · view · access: —

> Get current aPNTs USD price

*@dev* Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation

| returns | type | description |
|---|---|---|
| `price` | `uint256` | aPNTs price in USD (18 decimals) |

#### `getTokenAddress(address community)`

`0xb8d7b669` · view · access: —

> Get xPNTs token address for community

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `token` | `address` | Token address |

#### `hasToken(address community)`

`0x9bb0f599` · view · access: —

> Check if community has deployed token

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `exists` | `bool` | True if token exists |

#### `isXPNTs(address token)`

`0x96e28d28` · view · access: —

> Check if `token` was deployed via this factory and is therefore         a trusted xPNTs token (subject to firewall + per-tx caps).

*@dev* P0-12a: SuperPaymaster `settleX402PaymentDirect` MUST gate on this         check so that an attacker cannot drain a victim's standard         `approve(facilitator, MAX)` on USDC / WETH / etc. via the Direct         path. Only xPNTs tokens are protected by the autoApproved firewall.

| param | type | description |
|---|---|---|
| `token` | `address` | Token address to verify |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True iff the factory deployed this token (xPNTs). |

## IxPNTsToken

- **Source:** `contracts/src/interfaces/IxPNTsToken.sol`
- **Functions:** 7 · **Events:** 0 · **Errors:** 0
- **Title:** IxPNTsToken
- Interface for xPNTsToken contract

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xeca9f014` | `approvedFacilitators(address)` | view | — | Check whether a facilitator is authorized by this community to         settle x402 Direct payments against this xPNTs token. |
| `0xb83aa2de` | `burnFromWithOpHash(address,uint256,bytes32)` | nonpayable | — | Secure burn by Paymaster with replay protection. Amount in aPNTs;         xPNTs burned = amountAPNTs * exchangeRate / 1e18 (ceil). |
| `0x3ba0b9a9` | `exchangeRate()` | view | — | Get exchange rate with aPNTs |
| `0x2dd31000` | `FACTORY()` | view | — | Get factory address that created this token |
| `0x9a78e72e` | `getDebt(address)` | view | — | Get user debt amount in aPNTs (protocol unit) |
| `0xfa74542d` | `recordDebt(address,uint256)` | nonpayable | — | Record user debt (only SuperPaymaster). Amount in aPNTs. |
| `0x30f53441` | `recordDebtWithOpHash(address,uint256,bytes32)` | nonpayable | — | Record user debt with opHash replay protection (P1-17). Amount in aPNTs. |

### Functions

#### `approvedFacilitators(address facilitator)`

`0xeca9f014` · view · access: —

> Check whether a facilitator is authorized by this community to         settle x402 Direct payments against this xPNTs token.

*@dev* P0-12b (D4): community-controlled whitelist. SuperPaymaster         consults this in `settleX402PaymentDirect` so that a compromised         or untrusted facilitator with a valid global role still cannot         touch a community's xPNTs.

| param | type | description |
|---|---|---|
| `facilitator` | `address` | Facilitator address to check. |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True iff this xPNTs has authorized `facilitator`. |

#### `burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32 userOpHash)`

`0xb83aa2de` · nonpayable · access: —

> Secure burn by Paymaster with replay protection. Amount in aPNTs;         xPNTs burned = amountAPNTs * exchangeRate / 1e18 (ceil).

| param | type | description |
|---|---|---|
| `from` | `address` | User address |
| `amountAPNTs` | `uint256` | aPNTs amount to settle (converted to xPNTs internally) |
| `userOpHash` | `bytes32` | UserOperation hash for replay protection |

#### `exchangeRate()`

`0x3ba0b9a9` · view · access: —

> Get exchange rate with aPNTs

*@dev* xPNTs amount = aPNTs amount * exchangeRate / 1e18

| returns | type | description |
|---|---|---|
| `rate` | `uint256` | Exchange rate (18 decimals, 1e18 = 1:1) |

#### `FACTORY()`

`0x2dd31000` · view · access: —

> Get factory address that created this token

*@dev* Used by PaymasterV4 to verify token origin

| returns | type | description |
|---|---|---|
| `factory` | `address` | Factory contract address |

#### `getDebt(address user)`

`0x9a78e72e` · view · access: —

> Get user debt amount in aPNTs (protocol unit)

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `debt` | `uint256` | Debt amount in aPNTs |

#### `recordDebt(address user, uint256 amountAPNTs)`

`0xfa74542d` · nonpayable · access: —

> Record user debt (only SuperPaymaster). Amount in aPNTs.

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `amountAPNTs` | `uint256` | Debt amount in aPNTs (protocol unit) |

#### `recordDebtWithOpHash(address user, uint256 amountAPNTs, bytes32 opHash)`

`0x30f53441` · nonpayable · access: —

> Record user debt with opHash replay protection (P1-17). Amount in aPNTs.

*@dev* Preferred over recordDebt; reverts if the same opHash was already processed

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `amountAPNTs` | `uint256` | Debt amount in aPNTs (protocol unit) |
| `opHash` | `bytes32` | UserOperation hash — used as replay guard key |

## IAgentIdentityRegistry

- **Source:** `contracts/src/interfaces/v3/IAgentIdentityRegistry.sol`
- **Functions:** 3 · **Events:** 0 · **Errors:** 0
- **Title:** IAgentIdentityRegistry - ERC-8004 Agent Identity
- Interface for ERC-8004 compliant agent identity registries

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x70a08231` | `balanceOf(address)` | view | — | ERC-721 compatibility: token balance for an owner |
| `0xe21b38d2` | `isRegisteredAgent(address)` | view | — | Check if an address is a registered ERC-8004 agent |
| `0x6352211e` | `ownerOf(uint256)` | view | — | ERC-721 compatibility: owner of a specific token |

### Functions

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

> ERC-721 compatibility: token balance for an owner

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `isRegisteredAgent(address account)`

`0xe21b38d2` · view · access: —

> Check if an address is a registered ERC-8004 agent

| param | type | description |
|---|---|---|
| `account` | `address` | The address to query |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if the address holds a valid agent identity |

#### `ownerOf(uint256 agentId)`

`0x6352211e` · view · access: —

> ERC-721 compatibility: owner of a specific token

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

## IAgentReputationRegistry

- **Source:** `contracts/src/interfaces/v3/IAgentReputationRegistry.sol`
- **Functions:** 2 · **Events:** 0 · **Errors:** 0
- **Title:** IAgentReputationRegistry - ERC-8004 Agent Reputation
- Minimal interface for agent reputation queries and feedback

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x31259cff` | `getSummary(uint256,address[],bytes32,bytes32)` | view | — |  |
| `0x50e04768` | `giveFeedback(uint256,int128,uint8,bytes32,bytes32,string,string,bytes32)` | nonpayable | — |  |

### Functions

#### `getSummary(uint256 agentId, address[] clients, bytes32 tag1, bytes32 tag2)`

`0x31259cff` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clients` | `address[]` |  |
| `tag1` | `bytes32` |  |
| `tag2` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |
| `avgScore` | `int128` |  |

#### `giveFeedback(uint256 agentId, int128 value, uint8 decimals, bytes32 tag1, bytes32 tag2, string endpoint, string feedbackURI, bytes32 fileHash)`

`0x50e04768` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `value` | `int128` |  |
| `decimals` | `uint8` |  |
| `tag1` | `bytes32` |  |
| `tag2` | `bytes32` |  |
| `endpoint` | `string` |  |
| `feedbackURI` | `string` |  |
| `fileHash` | `bytes32` |  |

## IBLSAggregator

- **Source:** `contracts/src/interfaces/v3/IBLSAggregator.sol`
- **Functions:** 5 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x53f10a4b` | `defaultThreshold()` | view | — |  |
| `0xc85501bb` | `minThreshold()` | view | — |  |
| `0x6578b0cc` | `setDVTValidator(address)` | nonpayable | — |  |
| `0xfc3c298e` | `verify(bytes32,uint256,uint256,bytes)` | view | — | External BLS verification entry point (P0-1). |
| `0x2399c309` | `verifyAndExecute(uint256,address,uint8,address[],uint256[],uint256,bytes)` | nonpayable | — |  |

### Functions

#### `defaultThreshold()`

`0x53f10a4b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `minThreshold()`

`0xc85501bb` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `setDVTValidator(address _dvt)`

`0x6578b0cc` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_dvt` | `address` |  |

#### `verify(bytes32 expectedMessageHash, uint256 signerMask, uint256 requiredThreshold, bytes sigBytes)`

`0xfc3c298e` · view · access: —

> External BLS verification entry point (P0-1).

*@dev* Both pkAgg and msgG2 are reconstructed on-chain — callers cannot         supply them. Returns true iff the BLS12-381 pairing check passes         and the selected validator set meets `requiredThreshold`.

| param | type | description |
|---|---|---|
| `expectedMessageHash` | `bytes32` |  |
| `signerMask` | `uint256` |  |
| `requiredThreshold` | `uint256` |  |
| `sigBytes` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `verifyAndExecute(uint256 proposalId, address operator, uint8 slashLevel, address[] repUsers, uint256[] newScores, uint256 epoch, bytes proof)`

`0x2399c309` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |
| `operator` | `address` |  |
| `slashLevel` | `uint8` |  |
| `repUsers` | `address[]` |  |
| `newScores` | `uint256[]` |  |
| `epoch` | `uint256` |  |
| `proof` | `bytes` |  |

## IERC3009

- **Source:** `contracts/src/interfaces/v3/IERC3009.sol`
- **Functions:** 2 · **Events:** 0 · **Errors:** 0
- **Title:** IERC3009 - EIP-3009 Transfer With Authorization Interface
- Minimal interface for EIP-3009 compliant tokens (e.g., USDC v2.2+)

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x88b7ab63` | `receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | — | Receiver-driven EIP-3009 transfer. The token MUST enforce         `msg.sender == to`, so only the intended recipient (the         SuperPaymaster) can submit the authorization. This prevents a         front-runner from replaying the payer's signature directly on the         token to pull funds into the SuperPaymaster outside of a settlement. |
| `0xcf092995` | `transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | — |  |

### Functions

#### `receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature)`

`0x88b7ab63` · nonpayable · access: —

> Receiver-driven EIP-3009 transfer. The token MUST enforce         `msg.sender == to`, so only the intended recipient (the         SuperPaymaster) can submit the authorization. This prevents a         front-runner from replaying the payer's signature directly on the         token to pull funds into the SuperPaymaster outside of a settlement.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `signature` | `bytes` |  |

#### `transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature)`

`0xcf092995` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `signature` | `bytes` |  |

## IGTokenStaking

- **Source:** `contracts/src/interfaces/v3/IGTokenStaking.sol`
- **Functions:** 15 · **Events:** 5 · **Errors:** 0
- **Title:** IGTokenStaking
- GTokenStaking v4.2 interface — Unified Ticket Model

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xa0821be3` | `availableBalance(address)` | view | — | Get available (unlocked) balance |
| `0x70a08231` | `balanceOf(address)` | view | — | Get user's total staked balance |
| `0x7c50309f` | `getLockedStake(address,bytes32)` | view | — | Get locked stake amount for a role |
| `0x91b65cd6` | `getUserRoleLocks(address)` | view | — | Get all role locks for a user |
| `0x6d265c11` | `hasRoleLock(address,bytes32)` | view | — | Check if user has lock for a role |
| `0x9e9093da` | `lockStakeWithTicket(address,bytes32,uint256,uint256,address)` | nonpayable | — | Unified registration: handle ticket + optional stake for any role |
| `0xb4d81fb3` | `previewExitFee(address,bytes32)` | view | — | Preview exit fee for a role |
| `0x30b039ee` | `roleLocks(address,bytes32)` | view | — | Get role lock details |
| `0x36cb2b82` | `setAuthorizedSlasher(address,bool)` | nonpayable | — | Set authorized slasher |
| `0xd64c66aa` | `setRoleExitFee(bytes32,uint256,uint256)` | nonpayable | — | Set exit fee configuration for a role |
| `0x678b3ee2` | `slash(address,uint256,string)` | nonpayable | — | Slash a user's stake |
| `0x4bcb80a2` | `topUpStake(address,bytes32,uint256,address)` | nonpayable | — | Top up stake for an existing role (Registry only) |
| `0x817b1cd2` | `totalStaked()` | view | — | Get total staked in protocol |
| `0x374e4d73` | `unlockAndTransfer(address,bytes32)` | nonpayable | — | Unlock stake for a role and transfer to user (Registry only) |
| `0x54fd4d50` | `version()` | view | — | Get human-readable version string |

### Functions

#### `availableBalance(address user)`

`0xa0821be3` · view · access: —

> Get available (unlocked) balance

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Available balance for unstaking |

#### `balanceOf(address user)`

`0x70a08231` · view · access: —

> Get user's total staked balance

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Total staked GToken value |

#### `getLockedStake(address user, bytes32 roleId)`

`0x7c50309f` · view · access: —

> Get locked stake amount for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Locked amount for this role |

#### `getUserRoleLocks(address user)`

`0x91b65cd6` · view · access: —

> Get all role locks for a user

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `(uint128,uint128,uint48,bytes32,bytes)[]` | Array of role locks |

#### `hasRoleLock(address user, bytes32 roleId)`

`0x6d265c11` · view · access: —

> Check if user has lock for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if user has lock for this role |

#### `lockStakeWithTicket(address user, bytes32 roleId, uint256 stakeAmount, uint256 ticketPrice, address payer)`

`0x9e9093da` · nonpayable · access: —

> Unified registration: handle ticket + optional stake for any role

*@dev* Transfers (stakeAmount + ticketPrice) from payer.      When stakeAmount=0: ticket-only (no lock created).      When stakeAmount>0: ticket to treasury + stake locked.

| param | type | description |
|---|---|---|
| `user` | `address` | User registering for the role |
| `roleId` | `bytes32` | Role identifier |
| `stakeAmount` | `uint256` | Amount to lock as security deposit |
| `ticketPrice` | `uint256` | Amount to transfer to treasury |
| `payer` | `address` | Address providing the tokens |

| returns | type | description |
|---|---|---|
| `lockId` | `uint256` | Unique lock identifier |

#### `previewExitFee(address user, bytes32 roleId)`

`0xb4d81fb3` · view · access: —

> Preview exit fee for a role

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role to exit |

| returns | type | description |
|---|---|---|
| `fee` | `uint256` | Exit fee amount |
| `netAmount` | `uint256` | Amount after fee |

#### `roleLocks(address user, bytes32 roleId)`

`0x30b039ee` · view · access: —

> Get role lock details

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `amount` | `uint128` | Locked stGToken amount |
| `ticketPrice` | `uint128` | Ticket price paid to treasury on entry |
| `lockedAt` | `uint48` | Lock timestamp |
| `roleId_` | `bytes32` | The role ID |
| `metadata` | `bytes` | Additional role-specific data |

#### `setAuthorizedSlasher(address slasher, bool authorized)`

`0x36cb2b82` · nonpayable · access: —

> Set authorized slasher

| param | type | description |
|---|---|---|
| `slasher` | `address` | Address to authorize |
| `authorized` | `bool` | Authorization status |

#### `setRoleExitFee(bytes32 roleId, uint256 feePercent, uint256 minFee)`

`0xd64c66aa` · nonpayable · access: —

> Set exit fee configuration for a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |
| `feePercent` | `uint256` | Fee percentage (basis points) |
| `minFee` | `uint256` | Minimum fee amount |

#### `slash(address user, uint256 amount, string reason)`

`0x678b3ee2` · nonpayable · access: —

> Slash a user's stake

| param | type | description |
|---|---|---|
| `user` | `address` | User to slash |
| `amount` | `uint256` | Amount to slash |
| `reason` | `string` | Slash reason |

| returns | type | description |
|---|---|---|
| `slashedAmount` | `uint256` | Actual amount slashed |

#### `topUpStake(address user, bytes32 roleId, uint256 stakeAmount, address payer)`

`0x4bcb80a2` · nonpayable · access: —

> Top up stake for an existing role (Registry only)

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `roleId` | `bytes32` | Role identifier |
| `stakeAmount` | `uint256` | Amount to add |
| `payer` | `address` | Address providing the tokens |

#### `totalStaked()`

`0x817b1cd2` · view · access: —

> Get total staked in protocol

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Total GToken staked |

#### `unlockAndTransfer(address user, bytes32 roleId)`

`0x374e4d73` · nonpayable · access: —

> Unlock stake for a role and transfer to user (Registry only)

*@dev* SECURITY: Automatically transfers unlocked tokens to prevent re-lock attacks      MUST be called only by authorized Registry contract      Implementation should have onlyRegistry modifier Why auto-transfer?   - If we just unlock without transfer, user could call lockStakeWithTicket() again   - This would bypass the exitRole() flow and keep role active with no stake   - Auto-transfer ensures user gets tokens immediately, can't re-lock

| param | type | description |
|---|---|---|
| `user` | `address` | User whose stake to unlock |
| `roleId` | `bytes32` | Role to unlock from |

| returns | type | description |
|---|---|---|
| `netAmount` | `uint256` | Amount transferred to user after exit fee |

#### `version()`

`0x54fd4d50` · view · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0xe4c76dcad70ec0bf6b921afbe6bb7b4950aedf705245ec68942ea9ecf00f8a0c` | `StakeLocked(address,bytes32,uint256,uint256,uint256)` |
| `0x9cadbc33680e22a2f04ed8eb0d7cc7f218ee9231b3473ed05904c7ec5e2d483d` | `StakeUnlocked(address,bytes32,uint256,uint256,uint256,uint256)` |
| `0xb095d4d7990b498e886fe544495d08fafb40e2675fd41d78e8abf3778ebcada4` | `SyncFailed(address,bytes)` |
| `0xfd8455407fc2a5f2a6f1ea576385d9201fe1b9bd1b3ecb8bdab57d320cfbb475` | `TicketBurned(address,bytes32,uint256,address)` |
| `0x6951689eba99e77d7e3b622f276c0ad8e36126c3c510f181b86d05d685eaa074` | `UserSlashed(address,uint256,string,uint256)` |

## IMySBT

- **Source:** `contracts/src/interfaces/v3/IMySBT.sol`
- **Functions:** 8 · **Events:** 0 · **Errors:** 0
- **Title:** IMySBT
- Interface for MySBT v3.0.0 - Minimal role-based SBT minting

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xc580163e` | `airdropMint(address,bytes32,bytes)` | nonpayable | — | Admin airdrop (called by Registry only) |
| `0x374e7fa3` | `burnSBT(address)` | nonpayable | — | Burn user's SBT (called by Registry only on final role exit) |
| `0x5afc4b5c` | `deactivateAllMemberships(address)` | nonpayable | — | Deactivate all community memberships for a user (called by Registry only) |
| `0xd977b66b` | `deactivateMembership(address,address)` | nonpayable | — | Deactivate user membership in community (called by Registry only) |
| `0xbf1fb0f2` | `getSBTData(uint256)` | view | — | Get metadata for a specific SBT |
| `0x80f4b8c8` | `getUserSBT(address)` | view | — | Get user's SBT token ID |
| `0x3e3e6842` | `mintForRole(address,bytes32,bytes)` | nonpayable | — | Mint SBT for role registration (called by Registry only) |
| `0x5bb5bf0c` | `verifyCommunityMembership(address,address)` | view | — | Verify user has active membership in community |

### Functions

#### `airdropMint(address user, bytes32 roleId, bytes roleData)`

`0xc580163e` · nonpayable · access: —

> Admin airdrop (called by Registry only)

*@dev* DAO-paid minting: Registry.safeMintForRole() → this function      Registry handles all financial operations (staking/burning)

| param | type | description |
|---|---|---|
| `user` | `address` | User address to receive SBT |
| `roleId` | `bytes32` | Role identifier |
| `roleData` | `bytes` | Role-specific metadata |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` | Token ID (new or existing) |
| `isNewMint` | `bool` | True if new SBT was minted |

#### `burnSBT(address user)`

`0x374e7fa3` · nonpayable · access: —

> Burn user's SBT (called by Registry only on final role exit)

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

#### `deactivateAllMemberships(address user)`

`0x5afc4b5c` · nonpayable · access: —

> Deactivate all community memberships for a user (called by Registry only)

*@dev* H-02 FIX: Used when user exits ENDUSER role to clean up all memberships

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

#### `deactivateMembership(address user, address community)`

`0xd977b66b` · nonpayable · access: —

> Deactivate user membership in community (called by Registry only)

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `community` | `address` | Community address |

#### `getSBTData(uint256 tokenId)`

`0xbf1fb0f2` · view · access: —

> Get metadata for a specific SBT

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` | Token ID |

| returns | type | description |
|---|---|---|
| `data` | `(address,address,uint256,uint256)` | SBT data struct |

#### `getUserSBT(address user)`

`0x80f4b8c8` · view · access: —

> Get user's SBT token ID

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` | Token ID (0 if no SBT) |

#### `mintForRole(address user, bytes32 roleId, bytes roleData)`

`0x3e3e6842` · nonpayable · access: —

> Mint SBT for role registration (called by Registry only)

*@dev* Self-service registration: user registers via Registry.registerRole()

| param | type | description |
|---|---|---|
| `user` | `address` | User address to receive SBT |
| `roleId` | `bytes32` | Role identifier (bytes32) |
| `roleData` | `bytes` | Role-specific metadata (ABI-encoded) |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` | Token ID (new or existing) |
| `isNewMint` | `bool` | True if new SBT was minted |

#### `verifyCommunityMembership(address user, address community)`

`0x5bb5bf0c` · view · access: —

> Verify user has active membership in community

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `isValid` | `bool` | True if user has active membership |

## IRegistry

- **Source:** `contracts/src/interfaces/v3/IRegistry.sol`
- **Functions:** 18 · **Events:** 7 · **Errors:** 1
- **Title:** IRegistry
- Registry v3 interface with unified registerRole API

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x1b02e44f` | `batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)` | nonpayable | — | Batch update global reputation |
| `0x5ee05b17` | `configureRole(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256))` | nonpayable | — | Configure or create a role |
| `0x727b52a5` | `exitRole(bytes32)` | nonpayable | — | Exit from a role |
| `0x2c333e25` | `getCreditLimit(address)` | view | — | Get credit limit for user based on reputation |
| `0x913e6779` | `getEffectiveStake(address,bytes32)` | view | — | Effective stake read directly from Staking (source of truth). |
| `0xb5e936ab` | `getRoleConfig(bytes32)` | view | — | Get role configuration |
| `0x4b8b8a6e` | `getRoleUserCount(bytes32)` | view | — | Get total users with a specific role |
| `0x06a36aee` | `getUserRoles(address)` | view | — | Get all roles for a user |
| `0x91d14854` | `hasRole(bytes32,address)` | view | — | Check if user has a specific role |
| `0xbf28c98a` | `isReputationSource(address)` | view | — |  |
| `0x424a3d77` | `markProposalExecuted(uint256)` | nonpayable | — | Mark a BLS proposal as executed (called by BLSAggregator for slash-only proposals) |
| `0x669d7762` | `registerRole(bytes32,address,bytes)` | nonpayable | — | Register a user for a specific role (unified API) |
| `0x17e1c595` | `safeMintForRole(bytes32,address,bytes)` | nonpayable | — | Mint SBT for multiple users in a role (admin function) |
| `0x15de32ca` | `setCreditTier(uint256,uint256)` | nonpayable | — | Configure credit limit for a level |
| `0x6229738c` | `setReputationSource(address,bool)` | nonpayable | — | Authorize or revoke a reputation source |
| `0x7d960e37` | `syncStakeFromStaking(address,bytes32,uint256)` | nonpayable | — | Push a fresh stake snapshot from Staking into Registry's         per-role cache. |
| `0xce830e7b` | `updateOperatorBlacklist(address,address[],bool[],bytes)` | nonpayable | — | Update operator blacklist (via DVT consensus) |
| `0x54fd4d50` | `version()` | view | — | Get human-readable version string |

### Functions

#### `batchUpdateGlobalReputation(uint256 proposalId, address[] users, uint256[] newScores, uint256 epoch, bytes proof)`

`0x1b02e44f` · nonpayable · access: —

> Batch update global reputation

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |
| `users` | `address[]` | Users to update |
| `newScores` | `uint256[]` | New scores |
| `epoch` | `uint256` | Update epoch |
| `proof` | `bytes` | DVT signature proof |

#### `configureRole(bytes32 roleId, (uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256) config)`

`0x5ee05b17` · nonpayable · access: —

> Configure or create a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role to configure |
| `config` | `(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256)` | New configuration (must include owner) |

#### `exitRole(bytes32 roleId)`

`0x727b52a5` · nonpayable · access: —

> Exit from a role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role to exit from |

#### `getCreditLimit(address user)`

`0x2c333e25` · view · access: —

> Get credit limit for user based on reputation

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Credit limit in aPNTs (18 decimals) |

#### `getEffectiveStake(address user, bytes32 roleId)`

`0x913e6779` · view · access: —

> Effective stake read directly from Staking (source of truth).

*@dev* P0-14: consumers that cannot tolerate any drift should use         this rather than reading `roleStakes` directly.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getRoleConfig(bytes32 roleId)`

`0xb5e936ab` · view · access: —

> Get role configuration

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256)` | Role configuration |

#### `getRoleUserCount(bytes32 roleId)`

`0x4b8b8a6e` · view · access: —

> Get total users with a specific role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Total count |

#### `getUserRoles(address user)`

`0x06a36aee` · view · access: —

> Get all roles for a user

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `bytes32[]` | Array of role IDs |

#### `hasRole(bytes32 roleId, address user)`

`0x91d14854` · view · access: —

> Check if user has a specific role

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role to check |
| `user` | `address` | User address |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if user has the role |

#### `isReputationSource(address source)`

`0xbf28c98a` · view · access: —

| param | type | description |
|---|---|---|
| `source` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `markProposalExecuted(uint256 proposalId)`

`0x424a3d77` · nonpayable · access: —

> Mark a BLS proposal as executed (called by BLSAggregator for slash-only proposals)

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |

#### `registerRole(bytes32 roleId, address user, bytes roleData)`

`0x669d7762` · nonpayable · access: —

> Register a user for a specific role (unified API)

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role identifier (e.g., ROLE_COMMUNITY, ROLE_PAYMASTER) |
| `user` | `address` | User address to register |
| `roleData` | `bytes` | Encoded role-specific data |

#### `safeMintForRole(bytes32 roleId, address user, bytes roleData)`

`0x17e1c595` · nonpayable · access: —

> Mint SBT for multiple users in a role (admin function)

| param | type | description |
|---|---|---|
| `roleId` | `bytes32` | Role for minting |
| `user` | `address` | User to mint for |
| `roleData` | `bytes` | Role-specific data |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` | Minted token ID |

#### `setCreditTier(uint256 level, uint256 limit)`

`0x15de32ca` · nonpayable · access: —

> Configure credit limit for a level

| param | type | description |
|---|---|---|
| `level` | `uint256` |  |
| `limit` | `uint256` |  |

#### `setReputationSource(address source, bool isActive)`

`0x6229738c` · nonpayable · access: —

> Authorize or revoke a reputation source

| param | type | description |
|---|---|---|
| `source` | `address` |  |
| `isActive` | `bool` |  |

#### `syncStakeFromStaking(address user, bytes32 roleId, uint256 newAmount)`

`0x7d960e37` · nonpayable · access: —

> Push a fresh stake snapshot from Staking into Registry's         per-role cache.

*@dev* P0-14: only callable by the configured GTOKEN_STAKING. Used         by `slashByDVT` / `unlockAndTransfer` / topUp paths so that         Registry never drifts from Staking (INV-12).

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `roleId` | `bytes32` |  |
| `newAmount` | `uint256` |  |

#### `updateOperatorBlacklist(address operator, address[] users, bool[] statuses, bytes proof)`

`0xce830e7b` · nonpayable · access: —

> Update operator blacklist (via DVT consensus)

*@dev* Forwards the update to SuperPaymaster

| param | type | description |
|---|---|---|
| `operator` | `address` | The operator/community address |
| `users` | `address[]` | List of users to update |
| `statuses` | `bool[]` | Blocked status (true = blocked) |
| `proof` | `bytes` | DVT signature proof |

#### `version()`

`0x54fd4d50` · view · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0xe80f99d9789e367c229c526d3d3f84d44d3daf77ea65f7bbe8510f176ac45a23` | `BurnExecuted(address,bytes32,uint256,string)` |
| `0x287e005099116032e1bba9482a5b0df09cc99f7e82a4482fa2810c52158d473d` | `RoleConfigured(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256),uint256)` |
| `0x0d9361411a652b66cd4aed24a96d36c0b048899896c927d879a9d3ba2790d9c6` | `RoleExited(bytes32,address,uint256,uint256)` |
| `0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d` | `RoleGranted(bytes32,address,address)` |
| `0x2c48d754bbf59f20e71c13710fac35aa1ea020da58dcbb366de0ef7f75c9377d` | `RoleRegistered(bytes32,address,uint256,uint256)` |
| `0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b` | `RoleRevoked(bytes32,address,address)` |
| `0xf6da96ea84a034d6f30b7b377637742735f36f14cfda9144397e4f1e69116f4a` | `SBTBurnFailed(address,bytes32)` |

### Errors

| selector | error |
|---|---|
| `0xab338f96` | `BLSProofRequired()` |

## IReputationCalculator

- **Source:** `contracts/src/interfaces/v3/IReputationCalculator.sol`
- **Functions:** 3 · **Events:** 0 · **Errors:** 0
- **Title:** IReputationCalculator
- External reputation calculator interface for MySBT v2.1

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x9c4b3436` | `calculateReputation(address,address,uint256)` | view | — | Calculate reputation scores for a user |
| `0xff61c64e` | `getReputationBreakdown(address,address,uint256)` | view | — | Get reputation breakdown for transparency |
| `0x54fd4d50` | `version()` | view | — | Get human-readable version string |

### Functions

#### `calculateReputation(address user, address community, uint256 sbtTokenId)`

`0x9c4b3436` · view · access: —

> Calculate reputation scores for a user

*@dev* Implementation must be view/pure (no state changes)Should not revert - return 0 if user has no reputationCan call back to MySBT contract for membership/activity data

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `community` | `address` | Community address (for community-specific scoring) |
| `sbtTokenId` | `uint256` | User's SBT token ID |

| returns | type | description |
|---|---|---|
| `communityScore` | `uint256` | Community-specific reputation score |
| `globalScore` | `uint256` | Global cross-community reputation score |

#### `getReputationBreakdown(address user, address community, uint256 sbtTokenId)`

`0xff61c64e` · view · access: —

> Get reputation breakdown for transparency

*@dev* Optional - for UI display and debugging

| param | type | description |
|---|---|---|
| `user` | `address` | User address |
| `community` | `address` | Community address |
| `sbtTokenId` | `uint256` | User's SBT token ID |

| returns | type | description |
|---|---|---|
| `baseScore` | `uint256` | Base score from membership |
| `nftBonus` | `uint256` | Bonus from bound NFTs |
| `activityBonus` | `uint256` | Bonus from recent activity |
| `multiplier` | `uint256` | Community-specific multiplier (100 = 1x) |

#### `version()`

`0x54fd4d50` · view · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

## ISignatureTransfer

- **Source:** `contracts/src/interfaces/v3/ISignatureTransfer.sol`
- **Functions:** 2 · **Events:** 0 · **Errors:** 0
- **Title:** ISignatureTransfer - Uniswap Permit2 SignatureTransfer
- Minimal interface for Permit2 signature-based token transfers

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x30f28b7a` | `permitTransferFrom(((address,uint256),uint256,uint256),(address,uint256),address,bytes)` | nonpayable | — |  |
| `0x137c29fe` | `permitWitnessTransferFrom(((address,uint256),uint256,uint256),(address,uint256),address,bytes32,string,bytes)` | nonpayable | — |  |

### Functions

#### `permitTransferFrom(((address,uint256),uint256,uint256) permit, (address,uint256) transferDetails, address owner, bytes signature)`

`0x30f28b7a` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `permit` | `((address,uint256),uint256,uint256)` |  |
| `transferDetails` | `(address,uint256)` |  |
| `owner` | `address` |  |
| `signature` | `bytes` |  |

#### `permitWitnessTransferFrom(((address,uint256),uint256,uint256) permit, (address,uint256) transferDetails, address owner, bytes32 witness, string witnessTypeString, bytes signature)`

`0x137c29fe` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `permit` | `((address,uint256),uint256,uint256)` |  |
| `transferDetails` | `(address,uint256)` |  |
| `owner` | `address` |  |
| `witness` | `bytes32` |  |
| `witnessTypeString` | `string` |  |
| `signature` | `bytes` |  |

## MockAgentIdentityRegistry

- **Source:** `contracts/src/mocks/MockAgentIdentityRegistry.sol`
- **Functions:** 8 · **Events:** 3 · **Errors:** 2
- **Title:** MockAgentIdentityRegistry
- Minimal ERC-721-like mock for ERC-8004 Agent Identity testing

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x70a08231` | `balanceOf(address)` | view | — | Check if address holds agent NFT(s) |
| `0x61b8ce8c` | `nextId()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x6352211e` | `ownerOf(uint256)` | view | — | Get owner of agent ID |
| `0x306b9bb9` | `registerAgent(address)` | nonpayable | onlyOwner | Register an address as an agent (mint agent NFT) |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xba7550d4` | `revokeAgent(uint256)` | nonpayable | onlyOwner | Revoke agent status (burn agent NFT) |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |

### Functions

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

> Check if address holds agent NFT(s)

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `nextId()`

`0x61b8ce8c` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `ownerOf(uint256 agentId)`

`0x6352211e` · view · access: —

> Get owner of agent ID

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `registerAgent(address agent)`

`0x306b9bb9` · nonpayable · access: onlyOwner

> Register an address as an agent (mint agent NFT)

| param | type | description |
|---|---|---|
| `agent` | `address` |  |

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `revokeAgent(uint256 agentId)`

`0xba7550d4` · nonpayable · access: onlyOwner

> Revoke agent status (burn agent NFT)

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

### Events

| topic0 | event |
|---|---|
| `0xd1b844701695237443dd884ed7193d9c8788f3befd35adc0910472eb166f3306` | `AgentRegistered(address,uint256)` |
| `0xfff7a38bd0a2d198492b996b82c6bd083b224b0f43294f8a62fa6085f4d24ba4` | `AgentRevoked(uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |

### Errors

| selector | error |
|---|---|
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## MockAgentReputationRegistry

- **Source:** `contracts/src/mocks/MockAgentReputationRegistry.sol`
- **Functions:** 7 · **Events:** 2 · **Errors:** 2
- **Title:** MockAgentReputationRegistry
- Mock ERC-8004 Agent Reputation Registry for testing

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x31259cff` | `getSummary(uint256,address[],bytes32,bytes32)` | view | — | Get reputation summary for an agent |
| `0x50e04768` | `giveFeedback(uint256,int128,uint8,bytes32,bytes32,string,string,bytes32)` | nonpayable | — | Record feedback for an agent |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x72fa9b85` | `reputations(uint256)` | view | — |  |
| `0x27d39a08` | `setReputation(uint256,uint64,int128)` | nonpayable | onlyOwner | Set initial reputation for an agent (for testing) |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |

### Functions

#### `getSummary(uint256 agentId, address[] arg1, bytes32 arg2, bytes32 arg3)`

`0x31259cff` · view · access: —

> Get reputation summary for an agent

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `arg1` | `address[]` |  |
| `arg2` | `bytes32` |  |
| `arg3` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |
| `avgScore` | `int128` |  |

#### `giveFeedback(uint256 agentId, int128 value, uint8 arg2, bytes32 tag1, bytes32 tag2, string arg5, string arg6, bytes32 arg7)`

`0x50e04768` · nonpayable · access: —

> Record feedback for an agent

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `value` | `int128` |  |
| `arg2` | `uint8` |  |
| `tag1` | `bytes32` |  |
| `tag2` | `bytes32` |  |
| `arg5` | `string` |  |
| `arg6` | `string` |  |
| `arg7` | `bytes32` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `reputations(uint256 arg0)`

`0x72fa9b85` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `feedbackCount` | `uint64` |  |
| `totalScore` | `int128` |  |

#### `setReputation(uint256 agentId, uint64 count, int128 totalScore)`

`0x27d39a08` · nonpayable · access: onlyOwner

> Set initial reputation for an agent (for testing)

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `count` | `uint64` |  |
| `totalScore` | `int128` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

### Events

| topic0 | event |
|---|---|
| `0x93cbbbde8af84d8fc357f6ab6d867a7ec6262f8e613b727c93efe93f8a07fd07` | `FeedbackReceived(uint256,int128,bytes32,bytes32)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |

### Errors

| selector | error |
|---|---|
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## MockBLSAggregator

- **Source:** `contracts/src/mocks/MockBLSAggregator.sol`
- **Functions:** 8 · **Events:** 0 · **Errors:** 0
- **Title:** MockBLSAggregator
- Mock aggregator for unit tests — bypasses real BLS pairing.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x53f10a4b` | `defaultThreshold()` | view | — |  |
| `0xc85501bb` | `minThreshold()` | view | — |  |
| `0x6578b0cc` | `setDVTValidator(address)` | pure | — |  |
| `0xe3064a77` | `setThresholds(uint256,uint256)` | nonpayable | — |  |
| `0xc7b6b080` | `setVerifyResult(bool)` | nonpayable | — |  |
| `0xfc3c298e` | `verify(bytes32,uint256,uint256,bytes)` | view | — |  |
| `0x2399c309` | `verifyAndExecute(uint256,address,uint8,address[],uint256[],uint256,bytes)` | pure | — |  |
| `0x0e514c72` | `verifyResult()` | view | — |  |

### Functions

#### `defaultThreshold()`

`0x53f10a4b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `minThreshold()`

`0xc85501bb` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `setDVTValidator(address arg0)`

`0x6578b0cc` · pure · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

#### `setThresholds(uint256 _min, uint256 _default)`

`0xe3064a77` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_min` | `uint256` |  |
| `_default` | `uint256` |  |

#### `setVerifyResult(bool ok)`

`0xc7b6b080` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `ok` | `bool` |  |

#### `verify(bytes32 arg0, uint256 arg1, uint256 arg2, bytes arg3)`

`0xfc3c298e` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |
| `arg1` | `uint256` |  |
| `arg2` | `uint256` |  |
| `arg3` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `verifyAndExecute(uint256 arg0, address arg1, uint8 arg2, address[] arg3, uint256[] arg4, uint256 arg5, bytes arg6)`

`0x2399c309` · pure · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |
| `arg1` | `address` |  |
| `arg2` | `uint8` |  |
| `arg3` | `address[]` |  |
| `arg4` | `uint256[]` |  |
| `arg5` | `uint256` |  |
| `arg6` | `bytes` |  |

#### `verifyResult()`

`0x0e514c72` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

## MockUSDT

- **Source:** `contracts/src/mocks/MockUSDT.sol`
- **Functions:** 14 · **Events:** 3 · **Errors:** 8
- **Title:** MockUSDT
- Mock USDT token for testing (6 decimals like real USDT)

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xdd62ed3e` | `allowance(address,address)` | view | — |  |
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x313ce567` | `decimals()` | pure | — | Returns 6 decimals to match real USDT |
| `0xb86d1d63` | `faucet(address)` | nonpayable | — | Public faucet function for testing |
| `0x40c10f19` | `mint(address,uint256)` | nonpayable | onlyOwner | Mint tokens to any address (for testing) |
| `0x06fdde03` | `name()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0x18160ddd` | `totalSupply()` | view | — |  |
| `0xa9059cbb` | `transfer(address,uint256)` | nonpayable | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |

### Functions

#### `allowance(address owner, address spender)`

`0xdd62ed3e` · view · access: —

*@dev* See {IERC20-allowance}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `approve(address spender, uint256 value)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC20-approve}. NOTE: If `value` is the maximum `uint256`, the allowance is not updated on `transferFrom`. This is semantically equivalent to an infinite approval. Requirements: - `spender` cannot be the zero address.

| param | type | description |
|---|---|---|
| `spender` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `balanceOf(address account)`

`0x70a08231` · view · access: —

*@dev* See {IERC20-balanceOf}.

| param | type | description |
|---|---|---|
| `account` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `decimals()`

`0x313ce567` · pure · access: —

> Returns 6 decimals to match real USDT

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `faucet(address to)`

`0xb86d1d63` · nonpayable · access: —

> Public faucet function for testing

| param | type | description |
|---|---|---|
| `to` | `address` | Recipient address |

#### `mint(address to, uint256 amount)`

`0x40c10f19` · nonpayable · access: onlyOwner

> Mint tokens to any address (for testing)

| param | type | description |
|---|---|---|
| `to` | `address` | Recipient address |
| `amount` | `uint256` | Amount to mint (in 6 decimals) |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* Returns the name of the token.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* Returns the symbol of the token, usually a shorter version of the name.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `totalSupply()`

`0x18160ddd` · view · access: —

*@dev* See {IERC20-totalSupply}.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transfer(address to, uint256 value)`

`0xa9059cbb` · nonpayable · access: —

*@dev* See {IERC20-transfer}. Requirements: - `to` cannot be the zero address. - the caller must have a balance of at least `value`.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferFrom(address from, address to, uint256 value)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC20-transferFrom}. Emits an {Approval} event indicating the updated allowance. This is not required by the EIP. See the note at the beginning of {ERC20}. NOTE: Does not update the allowance if the current allowance is the maximum `uint256`. Requirements: - `from` and `to` cannot be the zero address. - `from` must have a balance of at least `value`. - the caller must have allowance for ``from``'s tokens of at least `value`.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0xfb8f41b2` | `ERC20InsufficientAllowance(address,uint256,uint256)` |
| `0xe450d38c` | `ERC20InsufficientBalance(address,uint256,uint256)` |
| `0xe602df05` | `ERC20InvalidApprover(address)` |
| `0xec442f05` | `ERC20InvalidReceiver(address)` |
| `0x96c6fd1e` | `ERC20InvalidSender(address)` |
| `0x94280d62` | `ERC20InvalidSpender(address)` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## MyNFT

- **Source:** `contracts/src/mocks/MyNFT.sol`
- **Functions:** 18 · **Events:** 4 · **Errors:** 10

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x081812fc` | `getApproved(uint256)` | view | — |  |
| `0xe985e9c5` | `isApprovedForAll(address,address)` | view | — |  |
| `0x06fdde03` | `name()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x6352211e` | `ownerOf(uint256)` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x40d097c3` | `safeMint(address)` | nonpayable | onlyOwner |  |
| `0xb88d4fde` | `safeTransferFrom(address,address,uint256,bytes)` | nonpayable | — |  |
| `0x42842e0e` | `safeTransferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | nonpayable | — |  |
| `0x01ffc9a7` | `supportsInterface(bytes4)` | view | — |  |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0xc87b56dd` | `tokenURI(uint256)` | view | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x3ccfd60b` | `withdraw()` | nonpayable | onlyOwner |  |

### Functions

#### `approve(address to, uint256 tokenId)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC721-approve}.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

*@dev* See {IERC721-balanceOf}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getApproved(uint256 tokenId)`

`0x081812fc` · view · access: —

*@dev* See {IERC721-getApproved}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `isApprovedForAll(address owner, address operator)`

`0xe985e9c5` · view · access: —

*@dev* See {IERC721-isApprovedForAll}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* See {IERC721Metadata-name}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `ownerOf(uint256 tokenId)`

`0x6352211e` · view · access: —

*@dev* See {IERC721-ownerOf}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `safeMint(address to)`

`0x40d097c3` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `to` | `address` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId, bytes data)`

`0xb88d4fde` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |
| `data` | `bytes` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId)`

`0x42842e0e` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `setApprovalForAll(address operator, bool approved)`

`0xa22cb465` · nonpayable · access: —

*@dev* See {IERC721-setApprovalForAll}.

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `approved` | `bool` |  |

#### `supportsInterface(bytes4 interfaceId)`

`0x01ffc9a7` · view · access: —

*@dev* See {IERC165-supportsInterface}.

| param | type | description |
|---|---|---|
| `interfaceId` | `bytes4` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* See {IERC721Metadata-symbol}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `tokenURI(uint256 tokenId)`

`0xc87b56dd` · view · access: —

*@dev* See {IERC721Metadata-tokenURI}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `transferFrom(address from, address to, uint256 tokenId)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC721-transferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `withdraw()`

`0x3ccfd60b` · nonpayable · access: onlyOwner

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | `ApprovalForAll(address,address,bool)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x64283d7b` | `ERC721IncorrectOwner(address,uint256,address)` |
| `0x177e802f` | `ERC721InsufficientApproval(address,uint256)` |
| `0xa9fbf51f` | `ERC721InvalidApprover(address)` |
| `0x5b08ba18` | `ERC721InvalidOperator(address)` |
| `0x89c62b64` | `ERC721InvalidOwner(address)` |
| `0x64a0ae92` | `ERC721InvalidReceiver(address)` |
| `0x73c6ac6e` | `ERC721InvalidSender(address)` |
| `0x7e273289` | `ERC721NonexistentToken(uint256)` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## TestSBT

- **Source:** `contracts/src/mocks/TestSBT.sol`
- **Functions:** 15 · **Events:** 3 · **Errors:** 8
- **Title:** TestSBT
- Simple SBT for testing - anyone can mint

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x081812fc` | `getApproved(uint256)` | view | — |  |
| `0x9bb0f599` | `hasToken(address)` | view | — | Check if address has any SBT |
| `0xe985e9c5` | `isApprovedForAll(address,address)` | view | — |  |
| `0x6a627842` | `mint(address)` | nonpayable | — | Mint SBT to any address (for testing only) |
| `0x06fdde03` | `name()` | view | — |  |
| `0x6352211e` | `ownerOf(uint256)` | view | — |  |
| `0xb88d4fde` | `safeTransferFrom(address,address,uint256,bytes)` | nonpayable | — |  |
| `0x42842e0e` | `safeTransferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | nonpayable | — |  |
| `0x01ffc9a7` | `supportsInterface(bytes4)` | view | — |  |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0xc87b56dd` | `tokenURI(uint256)` | view | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |

### Functions

#### `approve(address to, uint256 tokenId)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC721-approve}.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

*@dev* See {IERC721-balanceOf}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getApproved(uint256 tokenId)`

`0x081812fc` · view · access: —

*@dev* See {IERC721-getApproved}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `hasToken(address user)`

`0x9bb0f599` · view · access: —

> Check if address has any SBT

| param | type | description |
|---|---|---|
| `user` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isApprovedForAll(address owner, address operator)`

`0xe985e9c5` · view · access: —

*@dev* See {IERC721-isApprovedForAll}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `mint(address to)`

`0x6a627842` · nonpayable · access: —

> Mint SBT to any address (for testing only)

| param | type | description |
|---|---|---|
| `to` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* See {IERC721Metadata-name}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `ownerOf(uint256 tokenId)`

`0x6352211e` · view · access: —

*@dev* See {IERC721-ownerOf}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId, bytes data)`

`0xb88d4fde` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |
| `data` | `bytes` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId)`

`0x42842e0e` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `setApprovalForAll(address operator, bool approved)`

`0xa22cb465` · nonpayable · access: —

*@dev* See {IERC721-setApprovalForAll}.

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `approved` | `bool` |  |

#### `supportsInterface(bytes4 interfaceId)`

`0x01ffc9a7` · view · access: —

*@dev* See {IERC165-supportsInterface}.

| param | type | description |
|---|---|---|
| `interfaceId` | `bytes4` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* See {IERC721Metadata-symbol}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `tokenURI(uint256 tokenId)`

`0xc87b56dd` · view · access: —

*@dev* See {IERC721Metadata-tokenURI}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `transferFrom(address from, address to, uint256 tokenId)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC721-transferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | `ApprovalForAll(address,address,bool)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x64283d7b` | `ERC721IncorrectOwner(address,uint256,address)` |
| `0x177e802f` | `ERC721InsufficientApproval(address,uint256)` |
| `0xa9fbf51f` | `ERC721InvalidApprover(address)` |
| `0x5b08ba18` | `ERC721InvalidOperator(address)` |
| `0x89c62b64` | `ERC721InvalidOwner(address)` |
| `0x64a0ae92` | `ERC721InvalidReceiver(address)` |
| `0x73c6ac6e` | `ERC721InvalidSender(address)` |
| `0x7e273289` | `ERC721NonexistentToken(uint256)` |

## BLSAggregator

- **Source:** `contracts/src/modules/monitoring/BLSAggregator.sol`
- **Functions:** 26 · **Events:** 12 · **Errors:** 25
- **Title:** BLSAggregator
- BLS signature aggregation and verification for DVT slash consensus (V3)

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x300b0b35` | `aggregatedSignatures(uint256)` | view | — |  |
| `0x53f10a4b` | `defaultThreshold()` | view | — |  |
| `0xbc8efe75` | `DVT_VALIDATOR()` | view | — |  |
| `0x3b60288a` | `executedProposals(uint256)` | view | — |  |
| `0x5e1a03a2` | `executeProposal(uint256,address,bytes,uint256,bytes)` | nonpayable | — | Execute any proposal via BLS consensus (Generic DVT) |
| `0xc2e7cbdd` | `getBLSPublicKey(address)` | view | — | View accessor returning the stored G1 public key + slot for a validator. |
| `0x714897df` | `MAX_VALIDATORS()` | view | — |  |
| `0xc85501bb` | `minThreshold()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x0d8b9eab` | `permissionlessBLSRegistration()` | view | — | H-02: when true, a staked ROLE_DVT validator may self-register their OWN         BLS key (with proof-of-possession) instead of requiring an owner call.         Default false — onboarding stays owner-gated (off-chain trust established         first) until governance flips it on. Closes the otherwise-inconsistent         path where Registry ROLE_DVT is permissionless (self-service stake) but         BLS-key registration here was owner-only. |
| `0xa74c1ca8` | `proposalNonces(uint256)` | view | — |  |
| `0xaded17c5` | `registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))` | nonpayable | — | Register a BLS validator's public key into a deterministic slot. |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xb33a3a62` | `revokeBLSPublicKey(address)` | nonpayable | onlyOwner | Revoke a previously registered BLS validator key. |
| `0xc5246bf5` | `setDefaultThreshold(uint256)` | nonpayable | onlyOwner | Set default threshold for legacy calls (verifyAndExecute) |
| `0x6578b0cc` | `setDVTValidator(address)` | nonpayable | onlyOwner |  |
| `0x7f39a939` | `setMinThreshold(uint256)` | nonpayable | onlyOwner | Set minimum consensus threshold (global floor) |
| `0xa9ea1992` | `setPermissionlessBLSRegistration(bool)` | nonpayable | onlyOwner | H-02: toggle permissionless (stake + proof-of-possession) self-registration         of BLS validator keys. Default off — flip on once governance is ready to let         staked ROLE_DVT validators onboard their own keys without an owner call. |
| `0xe79e9739` | `setSuperPaymaster(address)` | nonpayable | onlyOwner |  |
| `0x5ae48ba4` | `SUPERPAYMASTER()` | view | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0xa3c57093` | `validatorAtSlot(uint8)` | view | — | 1-indexed slot → validator address. signerMask bit `i` (0-indexed)         corresponds to validator at slot `i+1`. |
| `0xfc3c298e` | `verify(bytes32,uint256,uint256,bytes)` | view | — | External BLS pairing verification used by Registry / ReputationSystem. |
| `0x2399c309` | `verifyAndExecute(uint256,address,uint8,address[],uint256[],uint256,bytes)` | nonpayable | nonReentrant |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `aggregatedSignatures(uint256 arg0)`

`0x300b0b35` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `aggregatedSig` | `bytes` |  |
| `messageHash` | `bytes32` |  |
| `timestamp` | `uint256` |  |
| `verified` | `bool` |  |

#### `defaultThreshold()`

`0x53f10a4b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `DVT_VALIDATOR()`

`0xbc8efe75` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `executedProposals(uint256 arg0)`

`0x3b60288a` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `executeProposal(uint256 proposalId, address target, bytes callData, uint256 requiredThreshold, bytes proof)`

`0x5e1a03a2` · nonpayable · access: —

> Execute any proposal via BLS consensus (Generic DVT)

*@dev* Allows executing arbitrary calls to authorized target contracts after BLS signature verification.      The target contract is responsible for its own access control (checking msg.sender == BLSAggregator).

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` | Unique proposal ID |
| `target` | `address` | Target contract to call |
| `callData` | `bytes` | Encoded function call (abi.encodeCall) |
| `requiredThreshold` | `uint256` | Required number of signatures (must be >= minThreshold) |
| `proof` | `bytes` | BLS aggregated signature proof: abi.encode(uint256 signerMask, bytes sigG2) |

#### `getBLSPublicKey(address validator)`

`0xc2e7cbdd` · view · access: —

> View accessor returning the stored G1 public key + slot for a validator.

| param | type | description |
|---|---|---|
| `validator` | `address` |  |

| returns | type | description |
|---|---|---|
| `publicKey` | `(bytes32,bytes32,bytes32,bytes32)` |  |
| `slot` | `uint8` |  |
| `isActive` | `bool` |  |

#### `MAX_VALIDATORS()`

`0x714897df` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `minThreshold()`

`0xc85501bb` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `permissionlessBLSRegistration()`

`0x0d8b9eab` · view · access: —

> H-02: when true, a staked ROLE_DVT validator may self-register their OWN         BLS key (with proof-of-possession) instead of requiring an owner call.         Default false — onboarding stays owner-gated (off-chain trust established         first) until governance flips it on. Closes the otherwise-inconsistent         path where Registry ROLE_DVT is permissionless (self-service stake) but         BLS-key registration here was owner-only.

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `proposalNonces(uint256 arg0)`

`0xa74c1ca8` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `registerBLSPublicKey(address validator, (bytes32,bytes32,bytes32,bytes32) publicKey, uint8 slot, (bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32) popSignature)`

`0xaded17c5` · nonpayable · access: —

> Register a BLS validator's public key into a deterministic slot.

*@dev* P0-1: keys are stored uncompressed so `_reconstructPkAgg` can         feed them straight into the G1ADD precompile. The slot encodes         the validator's bit position in `signerMask` and is fixed at         registration to make the bitmap → key mapping unambiguous.         P0-1 sub-fix (on-curve + subgroup check): `_validateG1Point` is         called before storing to guarantee (a) the point is on the         BLS12-381 G1 curve and (b) it is in the prime-order subgroup r.         Without (b) an attacker can register a small-subgroup point that         contaminates the reconstructed pkAgg used in later pairing checks.         The identity point (point at infinity) is also rejected to prevent         key-cancellation attacks during aggregation.

| param | type | description |
|---|---|---|
| `validator` | `address` | validator address (used for events / dedup). |
| `publicKey` | `(bytes32,bytes32,bytes32,bytes32)` | uncompressed EIP-2537 G1 point (4×32 bytes). |
| `slot` | `uint8` | 1-indexed slot in [1..MAX_VALIDATORS]. Must not collide                    with another validator's already-bound slot. |
| `popSignature` | `(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)` | proof-of-possession (G2): the validator's BLS signature over                    their own public key. Ignored on the owner path; REQUIRED and                    verified on the permissionless self-registration path. |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `revokeBLSPublicKey(address validator)`

`0xb33a3a62` · nonpayable · access: onlyOwner

> Revoke a previously registered BLS validator key.

*@dev* P0 follow-up: stricter semantics than the prior idempotent stub.         Reverts with `KeyNotActive` if the key is not currently active so         off-chain operators get a clear failure signal instead of a         silent no-op. The full key bytes are intentionally preserved         (only `isActive` is cleared and `validatorAtSlot[slot]` is reset         to address(0)) so historical proofs that reference the slot can         still be audited via `getBLSPublicKey`. Re-registration of the         same validator must use `registerBLSPublicKey` again, which will         pass `_validateG1Point` and either reuse or claim a new slot.

| param | type | description |
|---|---|---|
| `validator` | `address` |  |

#### `setDefaultThreshold(uint256 _newThreshold)`

`0xc5246bf5` · nonpayable · access: onlyOwner

> Set default threshold for legacy calls (verifyAndExecute)

| param | type | description |
|---|---|---|
| `_newThreshold` | `uint256` |  |

#### `setDVTValidator(address _dv)`

`0x6578b0cc` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_dv` | `address` |  |

#### `setMinThreshold(uint256 _newThreshold)`

`0x7f39a939` · nonpayable · access: onlyOwner

> Set minimum consensus threshold (global floor)

| param | type | description |
|---|---|---|
| `_newThreshold` | `uint256` |  |

#### `setPermissionlessBLSRegistration(bool enabled)`

`0xa9ea1992` · nonpayable · access: onlyOwner

> H-02: toggle permissionless (stake + proof-of-possession) self-registration         of BLS validator keys. Default off — flip on once governance is ready to let         staked ROLE_DVT validators onboard their own keys without an owner call.

| param | type | description |
|---|---|---|
| `enabled` | `bool` |  |

#### `setSuperPaymaster(address _sp)`

`0xe79e9739` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_sp` | `address` |  |

#### `SUPERPAYMASTER()`

`0x5ae48ba4` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `validatorAtSlot(uint8 arg0)`

`0xa3c57093` · view · access: —

> 1-indexed slot → validator address. signerMask bit `i` (0-indexed)         corresponds to validator at slot `i+1`.

| param | type | description |
|---|---|---|
| `arg0` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `verify(bytes32 expectedMessageHash, uint256 signerMask, uint256 requiredThreshold, bytes sigBytes)`

`0xfc3c298e` · view · access: —

> External BLS pairing verification used by Registry / ReputationSystem.

*@dev* P0-1: callers cannot supply pkAgg or msgG2 anymore. Both are         derived deterministically — pkAgg from `signerMask` against the         on-chain validator set, msgG2 from `expectedMessageHash`. Returns         true iff the pairing equation holds and at least         `requiredThreshold` distinct on-chain validators are selected.

| param | type | description |
|---|---|---|
| `expectedMessageHash` | `bytes32` | The exact hash the signers committed to. |
| `signerMask` | `uint256` | Bitmask of signing validator slots (bit i = slot i+1). |
| `requiredThreshold` | `uint256` | Caller's minimum signer count requirement. |
| `sigBytes` | `bytes` | abi.encode(BLS.G2Point) of the aggregated G2 signature. |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `verifyAndExecute(uint256 proposalId, address operator, uint8 slashLevel, address[] repUsers, uint256[] newScores, uint256 epoch, bytes proof)`

`0x2399c309` · nonpayable · access: nonReentrant

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |
| `operator` | `address` |  |
| `slashLevel` | `uint8` |  |
| `repUsers` | `address[]` |  |
| `newScores` | `uint256[]` |  |
| `epoch` | `uint256` |  |
| `proof` | `bytes` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x544d98ba9bb0b5ddc2f49ab57954b76f6ff7ffba5e89a9bcb73bbf77ffa31ed3` | `BLSPublicKeyRegistered(address,uint8)` |
| `0x2cd272f77807374f441a41070466b148ec96b0a2426251231e1f61c1161f61b5` | `BLSPublicKeyRevoked(address,uint8)` |
| `0x25570636268585bc59ae9205d2d178daf60cb7751815b001ec09ba0ae72ba746` | `BLSVerificationStatus(uint256,bool)` |
| `0xea8290e94fa93ea70e8ae04f89229012a6a3afb80b6b604792bb931c09cafcba` | `DVTValidatorUpdated(address,address)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x1a8b72448c86ca4cfd93a54c5ef39ab3afd44079dd8c7f304d6892dd8c52ed13` | `PermissionlessBLSRegistrationSet(bool)` |
| `0xf75669458e39b3e450bebdf8e3f8396a4ca0b4057017be244aa5af43321b2807` | `ProposalExecuted(uint256,address,bytes32)` |
| `0x5ce6898a418ad55caa812016e4cdd4a200158714e584a9627d17df3369316ef3` | `ReputationEpochTriggered(uint256,uint256)` |
| `0xc01e569e10d83e340f392c404e4d6006701961fc894f6ac91d65194b023f5ccc` | `SignatureAggregated(uint256,bytes,uint256)` |
| `0x85137418138b73abf7daf3f3556f050e536be403436e0ee7649eaee69d1faaca` | `SlashExecuted(uint256,address,uint8)` |
| `0x1f7cd67c986d0cce4aa6f69075b5278a05438ef2a5d1abf6eeded51ba8123245` | `SuperPaymasterUpdated(address,address)` |
| `0xb06a54caabe58475c86c2bf9df3f2f06dd1213e9e10659c293117fe4893b274b` | `ThresholdUpdated(uint256,uint256)` |

### Errors

| selector | error |
|---|---|
| `0xe91340f2` | `EmptySignerMask()` |
| `0x8e4c8aa6` | `InvalidAddress(address)` |
| `0x88a808ec` | `InvalidBLSKey()` |
| `0xc5150ef8` | `InvalidBLSKeyNotInSubgroup()` |
| `0x74f54c6c` | `InvalidBLSKeyNotOnCurve()` |
| `0xaa33ade0` | `InvalidParameter(string)` |
| `0x7392754a` | `InvalidPoP()` |
| `0x0992f7ad` | `InvalidProposalId()` |
| `0xd6022e8e` | `InvalidSignatureCount(uint256,uint256)` |
| `0xd08525e9` | `InvalidTarget(address)` |
| `0xb2153d3a` | `KeyNotActive(address)` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x9591c9c4` | `PermissionlessRegistrationDisabled()` |
| `0x4eec80e6` | `ProposalAlreadyExecuted(uint256)` |
| `0x0418cb66` | `ProposalExecutionFailed(uint256,bytes)` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x729d0f6b` | `SignatureVerificationFailed()` |
| `0x558bc2f1` | `SlotAlreadyTaken(uint8)` |
| `0x839797cd` | `SlotOutOfRange(uint8)` |
| `0x4a2e5708` | `SlotValidatorRoleRevoked(uint8,address)` |
| `0x2fd6c425` | `SlotValidatorStakeBelowMinimum(uint8,address,uint256,uint256)` |
| `0x204cba09` | `StakingNotConfigured()` |
| `0xd86ad9cf` | `UnauthorizedCaller(address)` |
| `0xb9f63b78` | `UnknownValidatorSlot(uint8)` |

## IDVTValidator

- **Source:** `contracts/src/modules/monitoring/BLSAggregator.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x424a3d77` | `markProposalExecuted(uint256)` | nonpayable | — |  |

### Functions

#### `markProposalExecuted(uint256 proposalId)`

`0x424a3d77` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `proposalId` | `uint256` |  |

## IRegistryStakingAwareBLS

- **Source:** `contracts/src/modules/monitoring/BLSAggregator.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0
- Local sub-view of Registry used to fetch the staking pointer at         verification time. We cast `REGISTRY` to this narrower interface         rather than baking another constructor arg, so existing deploy         scripts (4 in production + multiple archives) keep their 3-arg         BLSAggregator construction unchanged. Mocks in the test suite         already implement this view (set via `setStakingAddr`).

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x826600ce` | `GTOKEN_STAKING()` | view | — |  |

### Functions

#### `GTOKEN_STAKING()`

`0x826600ce` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

## ISuperPaymasterSlash

- **Source:** `contracts/src/modules/monitoring/BLSAggregator.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x079d2d42` | `executeSlashWithBLS(address,uint8,bytes)` | nonpayable | — |  |

### Functions

#### `executeSlashWithBLS(address operator, uint8 level, bytes proof)`

`0x079d2d42` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `level` | `uint8` |  |
| `proof` | `bytes` |  |

## DVTValidator

- **Source:** `contracts/src/modules/monitoring/DVTValidator.sol`
- **Functions:** 16 · **Events:** 7 · **Errors:** 14
- **Title:** DVTValidator
- Distributed Validator Technology for operator monitoring (V3)

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x4d238c8e` | `addValidator(address)` | nonpayable | onlyOwner | Register a new DVT validator after verifying both role and stake. |
| `0xc06f58e8` | `BLS_AGGREGATOR()` | view | — |  |
| `0x8e24bc9a` | `createProposal(address,uint8,string)` | nonpayable | — |  |
| `0x08f41334` | `executeWithProof(uint256,address[],uint256[],uint256,bytes)` | nonpayable | onlyAuthorizedExecutor | Direct execution with an aggregated proof |
| `0xfacd743b` | `isValidator(address)` | view | — |  |
| `0x424a3d77` | `markProposalExecuted(uint256)` | nonpayable | — | Mark proposal as executed (called by BLSAggregator after successful execution) |
| `0x2ab09d14` | `nextProposalId()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x013cf08b` | `proposals(uint256)` | view | — |  |
| `0x349a2c26` | `pruneValidator(address)` | nonpayable | — | Permissionless eviction when a validator no longer meets the         role + stake requirements (P0 follow-up). |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0x40a141ff` | `removeValidator(address)` | nonpayable | onlyOwner | Owner-only forced removal — used when governance wants to evict         a validator regardless of their current role/stake state (e.g.         emergency response to an off-chain key compromise). |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xbc959101` | `setBLSAggregator(address)` | nonpayable | onlyOwner |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `addValidator(address _v)`

`0x4d238c8e` · nonpayable · access: onlyOwner

> Register a new DVT validator after verifying both role and stake.

*@dev* P0-2: Pre-V5.4 this was an unconditional `onlyOwner` write,         meaning the owner could grow the quorum with stake-less keys         and the entire DVT economic guarantee evaporated. Combined with         the BLS forgery (P0-1) it left the consensus layer with no real         skin-in-the-game backing.         The check reads minStake dynamically from         `Registry.getRoleConfig(ROLE_DVT)` so governance can tune the         floor via `Registry.configureRole` without redeploying. Initial         deploy-time floor is 200 ether GToken (10x previous default).KNOWN LIMITATION: Stake is validated at registration time only.      A validator can exit their GTokenStaking stake after registration      without isValidator[v] being cleared. Mitigation:      1. Off-chain: operators should periodically call removeValidator()         for addresses whose stake has dropped below minStake.      2. On-chain enforcement would require a callback from GTokenStaking         (out of scope for this fix; tracked as future enhancement).

| param | type | description |
|---|---|---|
| `_v` | `address` |  |

#### `BLS_AGGREGATOR()`

`0xc06f58e8` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `createProposal(address operator, uint8 level, string reason)`

`0x8e24bc9a` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `level` | `uint8` |  |
| `reason` | `string` |  |

| returns | type | description |
|---|---|---|
| `id` | `uint256` |  |

#### `executeWithProof(uint256 id, address[] repUsers, uint256[] newScores, uint256 epoch, bytes proof)`

`0x08f41334` · nonpayable · access: onlyAuthorizedExecutor

> Direct execution with an aggregated proof

| param | type | description |
|---|---|---|
| `id` | `uint256` |  |
| `repUsers` | `address[]` |  |
| `newScores` | `uint256[]` |  |
| `epoch` | `uint256` |  |
| `proof` | `bytes` |  |

#### `isValidator(address arg0)`

`0xfacd743b` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `markProposalExecuted(uint256 id)`

`0x424a3d77` · nonpayable · access: —

> Mark proposal as executed (called by BLSAggregator after successful execution)

*@dev* This is called after BLS proof verification succeeds

| param | type | description |
|---|---|---|
| `id` | `uint256` |  |

#### `nextProposalId()`

`0x2ab09d14` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `proposals(uint256 arg0)`

`0x013cf08b` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `operator` | `address` |  |
| `slashLevel` | `uint8` |  |
| `reason` | `string` |  |
| `executed` | `bool` |  |
| `exists` | `bool` |  |

#### `pruneValidator(address v)`

`0x349a2c26` · nonpayable · access: —

> Permissionless eviction when a validator no longer meets the         role + stake requirements (P0 follow-up).

*@dev* Anyone can call this. The function reverts (`ValidatorStillEligible`)         if the validator still has ROLE_DVT AND stake >= minStake — so it         only succeeds when there's a genuine drift between the local         flag and on-chain reality. This gives off-chain monitors / public-         goods bots a way to prune stale validators without waiting for         the owner. The BLS slot is NOT freed here; revocation of the BLS         key remains an `onlyOwner` action via `BLSAggregator.revokeBLSPublicKey`         to keep slot lifecycle decisions privileged.

| param | type | description |
|---|---|---|
| `v` | `address` |  |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `removeValidator(address v)`

`0x40a141ff` · nonpayable · access: onlyOwner

> Owner-only forced removal — used when governance wants to evict         a validator regardless of their current role/stake state (e.g.         emergency response to an off-chain key compromise).

| param | type | description |
|---|---|---|
| `v` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `setBLSAggregator(address _bls)`

`0xbc959101` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_bls` | `address` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x019f532f6e08ee8944dc2e7ac40f3c97ad4a20618aee847ddf7c502821c7dad4` | `BLSAggregatorUpdated(address,address)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x876b000c101c27e7aaff6a3254ea503d0e9bf516112d43803bd82989b1355235` | `ProposalCreated(uint256,address,uint8)` |
| `0x712ae1383f79ac853f8d882153778e0260ef8f03b504e2866e0593e04d2b291f` | `ProposalExecuted(uint256)` |
| `0xc47a1536197401b36a117101725a5dfa1495e2643f664e4a10289c7bba944447` | `ProposalSigned(uint256,address)` |
| `0x367bc3cec9a81b642b69cb2ec83e77eb3f403ab741030d9d98afc27999443077` | `ValidatorPruned(address,bool,uint256)` |
| `0xe1434e25d6611e0db941968fdc97811c982ac1602e951637d206f5fdda9dd8f1` | `ValidatorRemoved(address)` |

### Errors

| selector | error |
|---|---|
| `0xb0bd6aca` | `AlreadySigned()` |
| `0x37603bef` | `NotActiveValidator(address)` |
| `0x69d6514c` | `NotAuthorizedExecutor()` |
| `0x2ec5b449` | `NotValidator()` |
| `0xb3186f36` | `OnlyBLSAggregator()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0xd9c78e02` | `ProposalDoesNotExist()` |
| `0x997a3f56` | `ProposalExecutedAlready()` |
| `0x204cba09` | `StakingNotConfigured()` |
| `0x84536595` | `ValidatorMissingRole()` |
| `0x6264d57f` | `ValidatorRoleRevoked(address)` |
| `0x0208a005` | `ValidatorStakeBelowMinimum(uint256,uint256)` |
| `0xc23285bd` | `ValidatorStillEligible(address)` |

## IRegistryStakingAware

- **Source:** `contracts/src/modules/monitoring/DVTValidator.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0
- Local sub-view of Registry exposing the staking pointer. Kept here         (rather than on IRegistry) so existing mocks across the test suite         do not need to implement the GTOKEN_STAKING getter — DVTValidator         simply casts its registry reference to this narrower interface.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x826600ce` | `GTOKEN_STAKING()` | view | — |  |

### Functions

#### `GTOKEN_STAKING()`

`0x826600ce` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

## ReputationSystem

- **Source:** `contracts/src/modules/reputation/ReputationSystem.sol`
- **Functions:** 24 · **Events:** 6 · **Errors:** 9
- **Title:** ReputationSystem
- Advanced reputation calculation and management for the Mycelium Ecosystem.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xfc193b49` | `boostedCollections(uint256)` | view | — |  |
| `0x9c4b3436` | `calculateReputation(address,address,uint256)` | view | — | IReputationCalculator implementation for MySBT v2.1+ |
| `0xa981c9f5` | `communityActiveRules(address,uint256)` | view | — |  |
| `0xfb42a9bf` | `communityReputations(address,address)` | view | — |  |
| `0xa00e8f81` | `communityRules(address,bytes32)` | view | — |  |
| `0x74f99244` | `computeScore(address,address[],bytes32[][],uint256[][])` | view | — | Compute reputation for a user based on their community activities. |
| `0xbcd3697c` | `defaultRule()` | view | — |  |
| `0x8dbda2eb` | `entropyFactors(address)` | view | — |  |
| `0xce26b0e0` | `getActiveRules(address)` | view | — | Get all active rule IDs for a community |
| `0xff61c64e` | `getReputationBreakdown(address,address,uint256)` | view | — |  |
| `0x5db8b75b` | `MAX_BOOSTED_COLLECTIONS()` | view | — |  |
| `0xcf1c5456` | `nftCollectionBoost(address)` | view | — |  |
| `0x3425bfae` | `nftHoldStart(address,address)` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x097f6b7c` | `setCommunityReputation(address,address,uint256)` | nonpayable | — | Set specific community reputation score (called by DVT/Trusted Source) |
| `0x4a2357b9` | `setEntropyFactor(address,uint256)` | nonpayable | onlyOwner | Governance sets the Entropy Factor for a community. |
| `0x30cd71a8` | `setNFTBoost(address,uint256)` | nonpayable | onlyOwner |  |
| `0x6df80b4e` | `setRule(bytes32,uint256,uint256,uint256,string)` | nonpayable | — | Community admins can set their own scoring rules. |
| `0x9172ff45` | `syncToRegistry(address,address[],bytes32[][],uint256[][],uint256,bytes)` | nonpayable | — | Sync computed reputation score to the Registry for the given user. |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x2f446881` | `updateNFTHoldStart(address)` | nonpayable | — | Manually update NFT hold start time for reputation boost |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `boostedCollections(uint256 arg0)`

`0xfc193b49` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `calculateReputation(address user, address community, uint256 arg2)`

`0x9c4b3436` · view · access: —

> IReputationCalculator implementation for MySBT v2.1+

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `community` | `address` |  |
| `arg2` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `communityScore` | `uint256` |  |
| `globalScore` | `uint256` |  |

#### `communityActiveRules(address arg0, uint256 arg1)`

`0xa981c9f5` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `communityReputations(address arg0, address arg1)`

`0xfb42a9bf` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `communityRules(address arg0, bytes32 arg1)`

`0xa00e8f81` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `baseScore` | `uint256` |  |
| `activityBonus` | `uint256` |  |
| `maxBonus` | `uint256` |  |
| `description` | `string` |  |

#### `computeScore(address user, address[] communities, bytes32[][] ruleIds, uint256[][] activities)`

`0x74f99244` · view · access: —

> Compute reputation for a user based on their community activities.

*@dev* Activities are now mapped to rules.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `communities` | `address[]` |  |
| `ruleIds` | `bytes32[][]` |  |
| `activities` | `uint256[][]` |  |

| returns | type | description |
|---|---|---|
| `totalScore` | `uint256` |  |

#### `defaultRule()`

`0xbcd3697c` · view · access: —

| returns | type | description |
|---|---|---|
| `baseScore` | `uint256` |  |
| `activityBonus` | `uint256` |  |
| `maxBonus` | `uint256` |  |
| `description` | `string` |  |

#### `entropyFactors(address arg0)`

`0x8dbda2eb` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getActiveRules(address community)`

`0xce26b0e0` · view · access: —

> Get all active rule IDs for a community

| param | type | description |
|---|---|---|
| `community` | `address` | The community address |

| returns | type | description |
|---|---|---|
| `ruleIds` | `bytes32[]` | Array of active rule identifiers |

#### `getReputationBreakdown(address user, address community, uint256 arg2)`

`0xff61c64e` · view · access: —

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `community` | `address` |  |
| `arg2` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `baseScore` | `uint256` |  |
| `nftBonus` | `uint256` |  |
| `activityBonus` | `uint256` |  |
| `multiplier` | `uint256` |  |

#### `MAX_BOOSTED_COLLECTIONS()`

`0x5db8b75b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `nftCollectionBoost(address arg0)`

`0xcf1c5456` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `nftHoldStart(address arg0, address arg1)`

`0x3425bfae` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `setCommunityReputation(address community, address user, uint256 score)`

`0x097f6b7c` · nonpayable · access: —

> Set specific community reputation score (called by DVT/Trusted Source)

*@dev* Allows off-chain calculation results to be stored on-chain for specific communities.      Authorized callers: contract owner OR addresses whitelisted via Registry.isReputationSource().

| param | type | description |
|---|---|---|
| `community` | `address` |  |
| `user` | `address` |  |
| `score` | `uint256` |  |

#### `setEntropyFactor(address community, uint256 factor)`

`0x4a2357b9` · nonpayable · access: onlyOwner

> Governance sets the Entropy Factor for a community.

*@dev* 1e18 = 1.0. Lower factor increases "resistance" to reputation gain.

| param | type | description |
|---|---|---|
| `community` | `address` |  |
| `factor` | `uint256` |  |

#### `setNFTBoost(address collection, uint256 boost)`

`0x30cd71a8` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `collection` | `address` |  |
| `boost` | `uint256` |  |

#### `setRule(bytes32 ruleId, uint256 base, uint256 bonus, uint256 max, string desc)`

`0x6df80b4e` · nonpayable · access: —

> Community admins can set their own scoring rules.

*@dev* Restricted to the owner of the community role in the Registry.

| param | type | description |
|---|---|---|
| `ruleId` | `bytes32` |  |
| `base` | `uint256` |  |
| `bonus` | `uint256` |  |
| `max` | `uint256` |  |
| `desc` | `string` |  |

#### `syncToRegistry(address user, address[] communities, bytes32[][] ruleIds, uint256[][] activities, uint256 epoch, bytes proof)`

`0x9172ff45` · nonpayable · access: —

> Sync computed reputation score to the Registry for the given user.

*@dev* Computes score via computeScore then calls Registry.batchUpdateGlobalReputation.      The proposalId is derived deterministically from (user, epoch) to ensure uniqueness.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `communities` | `address[]` |  |
| `ruleIds` | `bytes32[][]` |  |
| `activities` | `uint256[][]` |  |
| `epoch` | `uint256` |  |
| `proof` | `bytes` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `updateNFTHoldStart(address collection)`

`0x2f446881` · nonpayable · access: —

> Manually update NFT hold start time for reputation boost

*@dev* Users must call this after acquiring a boosted NFT. Boost starts 7 days later.

| param | type | description |
|---|---|---|
| `collection` | `address` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x6c1649831c4a2bebf79dfe8a2623ce1f5c65c9ab62903600dc011ee60a11c408` | `CommunityReputationUpdated(address,address,uint256)` |
| `0x21281390931aaf470d02c340b1ca10fabd02c8d7cdd1efcdbb3dc3fe5a0d0749` | `EntropyFactorUpdated(address,uint256)` |
| `0xcde4878b12c6b6c93c3eb3433ffbfdb24eb29698d8ac6ac98caf5db49d823457` | `NFTBoostAdded(address,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xdb8ed69eccdb6ff5105e3934ba9b515bb1b9d366e3a0c25a5f852ee20b6783e2` | `ReputationComputed(address,uint256)` |
| `0x868a11f79934bfa7243fd979d39bf00f37050e24b3ffc20a11f12a8b7e48d995` | `RuleUpdated(address,bytes32,uint256,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x027d3798` | `DoesNotHoldNFT()` |
| `0xe6c4247b` | `InvalidAddress()` |
| `0xa2e2e542` | `InvalidCollection()` |
| `0xb4fa3fb3` | `InvalidInput()` |
| `0x8567cd48` | `MaxBoostedReached()` |
| `0xea8e4eb5` | `NotAuthorized()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x82b42900` | `Unauthorized()` |

## BasePaymasterUpgradeable

- **Source:** `contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol`
- **Functions:** 15 · **Events:** 3 · **Errors:** 10
- **Title:** BasePaymasterUpgradeable
- UUPS-compatible base paymaster for ERC-4337 v0.7

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x0396cb60` | `addStake(uint32)` | payable | onlyOwner |  |
| `0xd0e30db0` | `deposit()` | payable | onlyOwner |  |
| `0xb0d691fe` | `entryPoint()` | view | — | The EntryPoint contract (immutable for gas savings on hot path) |
| `0xc399ec88` | `getDeposit()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x7c627b21` | `postOp(uint8,bytes,uint256,uint256)` | nonpayable | — | Post-operation handler. Must verify sender is the entryPoint. |
| `0x52d1902d` | `proxiableUUID()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0xbb9fe6bf` | `unlockStake()` | nonpayable | onlyOwner |  |
| `0xad3cb1cc` | `UPGRADE_INTERFACE_VERSION()` | view | — |  |
| `0x4f1ef286` | `upgradeToAndCall(address,bytes)` | payable | — |  |
| `0x52b7512c` | `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)` | nonpayable | — | Payment validation: check if paymaster agrees to pay. Must verify sender is the entryPoint. Revert to reject this request. Note that bundlers will reject this method if it changes the state, unless the paymaster is trusted (whitelisted). The paymaster pre-pays using its deposit, and receive back a refund after the postOp method returns. |
| `0xc23a5cea` | `withdrawStake(address)` | nonpayable | onlyOwner |  |
| `0x205c2878` | `withdrawTo(address,uint256)` | nonpayable | onlyOwner |  |

### Functions

#### `addStake(uint32 unstakeDelaySec)`

`0x0396cb60` · payable · access: onlyOwner

| param | type | description |
|---|---|---|
| `unstakeDelaySec` | `uint32` |  |

#### `deposit()`

`0xd0e30db0` · payable · access: onlyOwner

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The EntryPoint contract (immutable for gas savings on hot path)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getDeposit()`

`0xc399ec88` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)`

`0x7c627b21` · nonpayable · access: —

> Post-operation handler. Must verify sender is the entryPoint.

| param | type | description |
|---|---|---|
| `mode` | `uint8` | - Enum with the following options:                        opSucceeded - User operation succeeded.                        opReverted  - User op reverted. The paymaster still has to pay for gas.                        postOpReverted - never passed in a call to postOp(). |
| `context` | `bytes` | - The context value returned by validatePaymasterUserOp |
| `actualGasCost` | `uint256` | - Actual gas used so far (without this postOp call). |
| `actualUserOpFeePerGas` | `uint256` | - the gas price this UserOp pays. This value is based on the UserOp's maxFeePerGas                        and maxPriorityFee (and basefee)                        It is not the same as tx.gasprice, which is what the bundler pays. |

#### `proxiableUUID()`

`0x52d1902d` · view · access: —

*@dev* Implementation of the ERC1822 {proxiableUUID} function. This returns the storage slot used by the implementation. It is used to validate the implementation's compatibility when performing an upgrade. IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `unlockStake()`

`0xbb9fe6bf` · nonpayable · access: onlyOwner

#### `UPGRADE_INTERFACE_VERSION()`

`0xad3cb1cc` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `upgradeToAndCall(address newImplementation, bytes data)`

`0x4f1ef286` · payable · access: —

*@dev* Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call encoded in `data`. Calls {_authorizeUpgrade}. Emits an {Upgraded} event.

| param | type | description |
|---|---|---|
| `newImplementation` | `address` |  |
| `data` | `bytes` |  |

#### `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 userOpHash, uint256 maxCost)`

`0x52b7512c` · nonpayable · access: —

> Payment validation: check if paymaster agrees to pay. Must verify sender is the entryPoint. Revert to reject this request. Note that bundlers will reject this method if it changes the state, unless the paymaster is trusted (whitelisted). The paymaster pre-pays using its deposit, and receive back a refund after the postOp method returns.

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` | - The user operation. |
| `userOpHash` | `bytes32` | - Hash of the user's request data. |
| `maxCost` | `uint256` | - The maximum cost of this transaction (based on maximum gas and gas price from userOp). |

| returns | type | description |
|---|---|---|
| `context` | `bytes` | - Value to send to a postOp. Zero length to signify postOp is not required. |
| `validationData` | `uint256` | - Signature and time-range of this operation, encoded the same as the return                          value of validateUserOperation.                          <20-byte> sigAuthorizer - 0 for valid signature, 1 to mark signature failure,                                                    other values are invalid for paymaster.                          <6-byte> validUntil - last timestamp this operation is valid. 0 for "indefinite"                          <6-byte> validAfter - first timestamp this operation is valid                          Note that the validation code cannot use block.timestamp (or block.number) directly. |

#### `withdrawStake(address to)`

`0xc23a5cea` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `to` | `address` |  |

#### `withdrawTo(address to, uint256 amount)`

`0x205c2878` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b` | `Upgraded(address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0x4c9c8ce3` | `ERC1967InvalidImplementation(address)` |
| `0xb398979f` | `ERC1967NonPayable()` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0xe07c8dba` | `UUPSUnauthorizedCallContext()` |
| `0xaa1d49a4` | `UUPSUnsupportedProxiableUUID(bytes32)` |

## MicroPaymentChannel

- **Source:** `contracts/src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol`
- **Functions:** 18 · **Events:** 8 · **Errors:** 21
- **Title:** MicroPaymentChannel
- Unidirectional payment channel for streaming micropayments.         Uses cumulative vouchers signed by the payer (or a delegated signer)         that the payee submits on-chain to settle accrued amounts.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x43d41c9e` | `closeChannel(bytes32,uint128,bytes)` | nonpayable | nonReentrant | Cooperatively close a channel. Payee submits final voucher,         receives settled amount, and payer gets the refund. |
| `0xe8a5a066` | `closedChannels(bytes32)` | view | — |  |
| `0xe7084b7e` | `closeTimeout()` | view | — | Dispute window (in seconds) after a close request before the payer can withdraw.         Owner-configurable between MIN_CLOSE_TIMEOUT and MAX_CLOSE_TIMEOUT. |
| `0x84b0196e` | `eip712Domain()` | view | — |  |
| `0x831c2b82` | `getChannel(bytes32)` | view | — | View function to retrieve channel state. |
| `0x783c29bb` | `MAX_CLOSE_TIMEOUT()` | view | — | Maximum allowed closeTimeout (24 hours). |
| `0x3545a608` | `MIN_CLOSE_TIMEOUT()` | view | — | Minimum allowed closeTimeout (5 minutes). |
| `0x8ef66e27` | `openChannel(address,address,uint128,bytes32,address)` | nonpayable | nonReentrant | Open a new unidirectional payment channel. |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x89ff9d78` | `requestCloseChannel(bytes32)` | nonpayable | nonReentrant | Request channel closure. Starts the dispute window. |
| `0x6221a1f5` | `setCloseTimeout(uint64)` | nonpayable | onlyOwner | Update the dispute window duration. |
| `0x3ab95af9` | `settleChannel(bytes32,uint128,bytes)` | nonpayable | nonReentrant | Settle accrued payment using a cumulative voucher. |
| `0xdd573587` | `topUpChannel(bytes32,uint128)` | nonpayable | nonReentrant | Top up an existing channel with additional funds. |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x54fd4d50` | `version()` | pure | — | Returns the contract version string. |
| `0x94739e87` | `VOUCHER_TYPEHASH()` | view | — |  |
| `0x0771c1d1` | `withdrawChannel(bytes32)` | nonpayable | nonReentrant | Unilaterally withdraw remaining funds after the dispute window. |

### Functions

#### `closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)`

`0x43d41c9e` · nonpayable · access: nonReentrant

> Cooperatively close a channel. Payee submits final voucher,         receives settled amount, and payer gets the refund.

*@dev* Only the payee can call. Finalizes the channel.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |
| `cumulativeAmount` | `uint128` | Final cumulative amount owed. |
| `signature` | `bytes` | EIP-712 voucher signature for the final amount. |

#### `closedChannels(bytes32 arg0)`

`0xe8a5a066` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `closeTimeout()`

`0xe7084b7e` · view · access: —

> Dispute window (in seconds) after a close request before the payer can withdraw.         Owner-configurable between MIN_CLOSE_TIMEOUT and MAX_CLOSE_TIMEOUT.

| returns | type | description |
|---|---|---|
| `_0` | `uint64` |  |

#### `eip712Domain()`

`0x84b0196e` · view · access: —

*@dev* See: https://eips.ethereum.org/EIPS/eip-5267

| returns | type | description |
|---|---|---|
| `fields` | `bytes1` |  |
| `name` | `string` |  |
| `version` | `string` |  |
| `chainId` | `uint256` |  |
| `verifyingContract` | `address` |  |
| `salt` | `bytes32` |  |
| `extensions` | `uint256[]` |  |

#### `getChannel(bytes32 channelId)`

`0x831c2b82` · view · access: —

> View function to retrieve channel state.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |

| returns | type | description |
|---|---|---|
| `_0` | `(address,address,address,address,uint128,uint128,uint64,bool)` | channel  The Channel struct. |

#### `MAX_CLOSE_TIMEOUT()`

`0x783c29bb` · view · access: —

> Maximum allowed closeTimeout (24 hours).

| returns | type | description |
|---|---|---|
| `_0` | `uint64` |  |

#### `MIN_CLOSE_TIMEOUT()`

`0x3545a608` · view · access: —

> Minimum allowed closeTimeout (5 minutes).

| returns | type | description |
|---|---|---|
| `_0` | `uint64` |  |

#### `openChannel(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner)`

`0x8ef66e27` · nonpayable · access: nonReentrant

> Open a new unidirectional payment channel.

| param | type | description |
|---|---|---|
| `payee` | `address` | Recipient of payments (service provider). |
| `token` | `address` | ERC-20 token used for payments. |
| `deposit` | `uint128` | Initial deposit amount (transferred from msg.sender). |
| `salt` | `bytes32` | User-provided salt for channelId uniqueness. |
| `authorizedSigner` | `address` | Delegated signer (e.g. AirAccount Session Key).                          Set to address(0) to require payer's own signature. |

| returns | type | description |
|---|---|---|
| `channelId` | `bytes32` | Deterministic identifier for this channel. |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `requestCloseChannel(bytes32 channelId)`

`0x89ff9d78` · nonpayable · access: nonReentrant

> Request channel closure. Starts the dispute window.

*@dev* Only the payer can call. The payee has closeTimeout seconds      to submit any remaining vouchers before the payer can withdraw.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |

#### `setCloseTimeout(uint64 _timeout)`

`0x6221a1f5` · nonpayable · access: onlyOwner

> Update the dispute window duration.

*@dev* Only the owner can call. The new value must be within      [MIN_CLOSE_TIMEOUT, MAX_CLOSE_TIMEOUT].

| param | type | description |
|---|---|---|
| `_timeout` | `uint64` | New timeout in seconds. |

#### `settleChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)`

`0x3ab95af9` · nonpayable · access: nonReentrant

> Settle accrued payment using a cumulative voucher.

*@dev* Only the payee can call. The voucher must be signed by the payer      or the channel's authorizedSigner.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |
| `cumulativeAmount` | `uint128` | Total cumulative amount owed (must exceed previous settled). |
| `signature` | `bytes` | EIP-712 voucher signature. |

#### `topUpChannel(bytes32 channelId, uint128 amount)`

`0xdd573587` · nonpayable · access: nonReentrant

> Top up an existing channel with additional funds.

*@dev* Only the payer can call.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |
| `amount` | `uint128` | Additional deposit amount. |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Returns the contract version string.

| returns | type | description |
|---|---|---|
| `_0` | `string` | Version identifier. |

#### `VOUCHER_TYPEHASH()`

`0x94739e87` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `withdrawChannel(bytes32 channelId)`

`0x0771c1d1` · nonpayable · access: nonReentrant

> Unilaterally withdraw remaining funds after the dispute window.

*@dev* Only the payer can call. Requires that a close was requested and      the timeout has elapsed.

| param | type | description |
|---|---|---|
| `channelId` | `bytes32` | Channel identifier. |

### Events

| topic0 | event |
|---|---|
| `0x3900aaf06a211844dfd71554da2fb6d449fb270e7b4b3a3c624d02329e570325` | `ChannelClosed(bytes32,uint128,uint128)` |
| `0x63c68527db63abeeb27e8ea4a2417a032ac5cd83b3ffaf2700c15ba4f6c15cf0` | `ChannelOpened(bytes32,address,address,address,uint128)` |
| `0xca804f3663aaa109bfb233841bc2956ef23bf9a64db0183b7387e04c48d322b1` | `ChannelSettled(bytes32,uint128,uint128)` |
| `0x73f79dc74e3752c88c5b0df459fdf3239308f420f0ead3f9fddbdf296dc35f0e` | `ChannelTopUp(bytes32,uint128,uint128)` |
| `0xfca9fa5eb605eef37bc81f65aa2978fdab527c2da02ea18e1b9847445f6eca0f` | `ChannelWithdrawn(bytes32,uint128)` |
| `0x9fd5c1db29e4aeb4f968f62fc18602aad1cca0f99be64b456a6c4f4052d63b14` | `CloseRequested(bytes32,uint64)` |
| `0xca899dbf080b3238e556d3924f56a15f7af0a4de975d19ae28431de5754f7542` | `CloseTimeoutUpdated(uint64,uint64)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0xcd786059` | `AddressInsufficientBalance(address)` |
| `0x23b87dad` | `ChannelAlreadyClosed()` |
| `0x0ec0f149` | `ChannelAlreadyExists()` |
| `0xc9f3b559` | `ChannelFinalized()` |
| `0x1e07dd94` | `ChannelNotFound()` |
| `0xf15dbef3` | `CloseNotRequested()` |
| `0x55a33f2c` | `CloseTimeoutNotElapsed()` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0x2c5211c6` | `InvalidAmount()` |
| `0xaa33ade0` | `InvalidParameter(string)` |
| `0x8baa579f` | `InvalidSignature()` |
| `0x81cc7a22` | `NonDecreasingSettlement()` |
| `0x3e7e2ec4` | `OnlyPayee()` |
| `0x27e7e93c` | `OnlyPayer()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x5274afe7` | `SafeERC20FailedOperation(address)` |
| `0xedeb5f3e` | `SelfChannel()` |
| `0x770d1ccb` | `SettlementExceedsDeposit()` |

## SuperPaymaster

- **Source:** `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`
- **Functions:** 96 · **Events:** 41 · **Errors:** 39
- **Title:** SuperPaymaster
- SuperPaymaster - Unified Registry based Multi-Operator Paymaster

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x0396cb60` | `addStake(uint32)` | payable | — |  |
| `0xde5c62a6` | `agentIdentityRegistry()` | view | — |  |
| `0x4382885d` | `agentReputationRegistry()` | view | — |  |
| `0xddd595ca` | `APNTS_TOKEN_TIMELOCK()` | view | — | Window between queueing an `setAPNTsToken` change and being         allowed to execute it. Owner can cancel any time during this         window. Picked to give all integrators (operators, SDKs,         off-chain monitors) at least one weekly review cycle to react. |
| `0x74f053c4` | `APNTS_TOKEN()` | view | — |  |
| `0x594a6f23` | `aPNTsPriceUSD()` | view | — |  |
| `0xa0c5018b` | `applyBLSAggregator()` | nonpayable | onlyOwner |  |
| `0xc06f58e8` | `BLS_AGGREGATOR()` | view | — |  |
| `0xf60fdcb3` | `cachedPrice()` | view | — |  |
| `0x1d2282c9` | `cancelAPNTsTokenChange()` | nonpayable | onlyOwner | Abort a queued APNTS_TOKEN swap before it executes. |
| `0x0c883112` | `cancelEmergencyPrice()` | nonpayable | onlyOwner | Cancel a queued emergency price. Useful when the multisig         realises the queued value is wrong before timelock elapses. |
| `0x5d2e7e50` | `clearPendingDebt(address,address)` | nonpayable | onlyOwner | Admin function to clear stuck pending debt (escape hatch) |
| `0x5c7c4b5f` | `configureOperator(address,address)` | nonpayable | — |  |
| `0xd0e30db0` | `deposit()` | payable | nonReentrant |  |
| `0xb6b55f25` | `deposit(uint256)` | nonpayable | nonReentrant | Deposit xPNTs tokens from msg.sender into their own operator balance. |
| `0x2f4f21e2` | `depositFor(address,uint256)` | nonpayable | nonReentrant | Deposit xPNTs tokens on behalf of a specific operator address. |
| `0x17a18778` | `dryRunValidation((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),uint256)` | view | — | P0-15 (J2-BLOCKER-1): pure-view diagnostic mirror of         validatePaymasterUserOp. Bundlers / SDKs / dApps call this         off-chain (eth_call) before submitting a UserOperation to         distinguish the 8 distinct rejection paths that         validatePaymasterUserOp returns as an opaque SIG_FAILURE. |
| `0x60d7442b` | `EMERGENCY_TIMELOCK()` | view | — |  |
| `0x3d63f215` | `emergencyActivatedAt()` | view | — | Timestamp at which EMERGENCY mode was first activated (i.e. first         `executeEmergencyPrice` call after a CHAINLINK→EMERGENCY transition).         Cleared to 0 on Chainlink recovery. Used to enforce EMERGENCY_EXPIRY. |
| `0x34fde76a` | `emergencyPendingPrice()` | view | — | Pending emergency price (8 decimals, same scale as Chainlink). |
| `0x75e09b51` | `emergencyQueuedAt()` | view | — | Timestamp at which `emergencySetPrice` was last called; 0 if none queued. |
| `0x96ea1e38` | `emergencySetPrice(int256)` | nonpayable | onlyOwner | Queue an emergency price update. Only honored when Chainlink         is stale and the new price stays within ±20% of the last         cached price; eligible for execution after a 1-hour timelock. |
| `0xb0d691fe` | `entryPoint()` | view | — | The EntryPoint contract (immutable for gas savings on hot path) |
| `0xb0f0abe9` | `ETH_USD_PRICE_FEED()` | view | — |  |
| `0x84450c3d` | `executeAPNTsTokenChange()` | nonpayable | onlyOwner | Apply a previously queued APNTS_TOKEN swap. |
| `0xdc61ae90` | `executeEmergencyPrice()` | nonpayable | — | Apply a previously queued emergency price. |
| `0x079d2d42` | `executeSlashWithBLS(address,uint8,bytes)` | nonpayable | — | Execute slash triggered by BLS consensus (DVT Module only) |
| `0xef842a46` | `facilitatorEarnings(address,address)` | view | — |  |
| `0xbac256d6` | `facilitatorFeeBPS()` | view | — |  |
| `0xeafe74b5` | `getAvailableCredit(address,address)` | view | — | Get operator credit limit for a user |
| `0xc399ec88` | `getDeposit()` | view | — |  |
| `0x8670d78d` | `getEffectiveFacilitatorFee(address)` | view | — | P1-39: Returns the effective facilitator fee for an operator. |
| `0xc1d9cb08` | `getLatestSlash(address)` | view | — |  |
| `0x66c36875` | `getSlashCount(address)` | view | — |  |
| `0xa134d63a` | `getSlashHistory(address)` | view | — |  |
| `0xcf756fdf` | `initialize(address,address,address,uint256)` | nonpayable | initializer | Initialize the UUPS proxy state |
| `0x8e0d8ed9` | `isChainlinkStale()` | view | — |  |
| `0x6a16e22d` | `isEligibleForSponsorship(address)` | view | — | V5.3: Dual-channel eligibility — SBT holder OR registered ERC-8004 agent |
| `0xe21b38d2` | `isRegisteredAgent(address)` | view | — | Check if an address is a registered ERC-8004 agent |
| `0x88a7ca5c` | `onTransferReceived(address,address,uint256,bytes)` | nonpayable | nonReentrant | Handle ERC1363 transferAndCall (Push Mode) |
| `0x928624e7` | `operatorFacilitatorFees(address)` | view | — |  |
| `0x13e7c9d8` | `operators(address)` | view | — | Get operator configuration |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x60a9139b` | `pendingAPNTsToken()` | view | — | Pending APNTS_TOKEN swap; address(0) when none queued. |
| `0xbb2ddb27` | `pendingAPNTsTokenEta()` | view | — | Earliest timestamp at which `executeAPNTsTokenChange` may run. |
| `0xb7b76cbe` | `pendingBLSAgg()` | view | — |  |
| `0xfe719e2f` | `pendingBLSAggEta()` | view | — |  |
| `0x7b707185` | `pendingDebts(address,address)` | view | — |  |
| `0x7c627b21` | `postOp(uint8,bytes,uint256,uint256)` | nonpayable | onlyEntryPoint, nonReentrant | Post-operation handler. Must verify sender is the entryPoint. |
| `0x07615815` | `priceMode()` | view | — | 0 = CHAINLINK (normal), 1 = EMERGENCY (owner override active). |
| `0xbd111870` | `priceStalenessThreshold()` | view | — | Price staleness threshold (seconds) |
| `0x82309dd8` | `priceValidUntil()` | view | — | Returns the timestamp after which the cached price is considered stale. |
| `0x96daa322` | `protocolFeeBPS()` | view | — |  |
| `0x7af3816c` | `protocolRevenue()` | view | — |  |
| `0x52d1902d` | `proxiableUUID()` | view | — |  |
| `0xb54a8fca` | `queueBLSAggregator(address)` | nonpayable | onlyOwner |  |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x8041c94a` | `retryPendingDebt(address,address,uint256)` | nonpayable | onlyOwner, nonReentrant | Retry recording a pending debt that failed during postOp. |
| `0xf7e8cb0d` | `sbtHolders(address)` | view | — |  |
| `0x6a4b23b1` | `setAgentRegistries(address,address)` | nonpayable | onlyOwner | Set ERC-8004 agent registries (Owner only) |
| `0xec2123f1` | `setAPNTSPrice(uint256)` | nonpayable | onlyOwner | Set the APNTS Price in USD (Owner Only) |
| `0xd20727d7` | `setAPNTsToken(address)` | nonpayable | onlyOwner | Queue a new APNTS_TOKEN. Cannot take effect until         `pendingAPNTsTokenEta` and only when both `totalTrackedBalance`         and `protocolRevenue` are within PROTOCOL_REVENUE_BUFFER (otherwise         existing operator deposits would be stranded under the new token's         accounting). |
| `0x2540c471` | `setFacilitatorFeeBPS(uint256)` | nonpayable | onlyOwner | Set default facilitator fee BPS (Owner only) |
| `0xc50cff87` | `setOperatorFacilitatorFee(address,uint256)` | nonpayable | onlyOwner | Set per-operator facilitator fee override (Owner only) |
| `0xfc347007` | `setOperatorLimits(uint48)` | nonpayable | — |  |
| `0xe8ade1a9` | `setOperatorPaused(address,bool)` | nonpayable | onlyOwner | Pause/Unpause an operator (Owner Only) |
| `0x787dce3d` | `setProtocolFee(uint256)` | nonpayable | onlyOwner | Set the protocol fee basis points (Owner Only) |
| `0xf3a729da` | `settleX402Payment(address,address,address,uint256,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | nonReentrant | Settle x402 payment via EIP-3009 receiveWithAuthorization (USDC native path) |
| `0x7344209c` | `settleX402PaymentDirect(address,address,address,uint256,uint256,uint256,bytes32,bytes)` | nonpayable | nonReentrant | Settle x402 payment via direct transferFrom (xPNTs only) |
| `0xf0f44260` | `setTreasury(address)` | nonpayable | onlyOwner | Set the protocol treasury address (Owner Only) |
| `0x58a2570a` | `setXPNTsFactory(address)` | nonpayable | onlyOwner |  |
| `0x8e580213` | `slashHistory(address,uint256)` | view | — |  |
| `0xbfa5a1eb` | `slashOperator(address,uint8,uint256,string)` | nonpayable | onlyOwner | Slash an operator (Admin/Governance only) |
| `0x61ad446e` | `totalTrackedBalance()` | view | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x61d027b3` | `treasury()` | view | — |  |
| `0xbb9fe6bf` | `unlockStake()` | nonpayable | — |  |
| `0x5f4cd4fe` | `updateBlockedStatus(address,address[],bool[])` | nonpayable | — | Batch update blocked status for users (Called by Registry via DVT) |
| `0x673a7e28` | `updatePrice()` | nonpayable | — | Update price cache from Chainlink oracle (keeper-callable). |
| `0x53afb8be` | `updatePriceDVT(int256,uint256,bytes,uint8)` | nonpayable | — | Update price via DVT/BLS consensus (Chainlink fallback) |
| `0xf5c91a08` | `updateReputation(address,uint256)` | nonpayable | onlyOwner | Update Operator Reputation (External Credit Manager) |
| `0xa3970ae6` | `updateSBTStatus(address,bool)` | nonpayable | — | Update SBT holder status (Called by Registry) |
| `0xad3cb1cc` | `UPGRADE_INTERFACE_VERSION()` | view | — |  |
| `0x4f1ef286` | `upgradeToAndCall(address,bytes)` | payable | — |  |
| `0x6640431f` | `userOpState(address,address)` | view | — |  |
| `0x52b7512c` | `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)` | nonpayable | onlyEntryPoint, nonReentrant | Payment validation: check if paymaster agrees to pay. Must verify sender is the entryPoint. Revert to reject this request. Note that bundlers will reject this method if it changes the state, unless the paymaster is trusted (whitelisted). The paymaster pre-pays using its deposit, and receive back a refund after the postOp method returns. |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |
| `0x2e1a7d4d` | `withdraw(uint256)` | nonpayable | nonReentrant | Withdraw aPNTs |
| `0xd4c38f52` | `withdrawFacilitatorEarnings(address)` | nonpayable | nonReentrant | Withdraw accumulated facilitator earnings |
| `0xa4b5328f` | `withdrawProtocolRevenue(address,uint256)` | nonpayable | onlyOwner, nonReentrant | Withdraw accumulated Protocol Revenue |
| `0xc23a5cea` | `withdrawStake(address)` | nonpayable | — |  |
| `0x205c2878` | `withdrawTo(address,uint256)` | nonpayable | — |  |
| `0x761cda33` | `x402NonceKey(address,address,bytes32)` | pure | — | Compose the per-(asset, from, nonce) replay-protection key. |
| `0x4ee1a3d6` | `x402SettlementNonces(bytes32)` | view | — | x402 settlement nonces, keyed by keccak256(asset, from, nonce). |
| `0x6d8a4aff` | `xpntsFactory()` | view | — |  |

### Functions

#### `addStake(uint32 unstakeDelaySec)`

`0x0396cb60` · payable · access: —

| param | type | description |
|---|---|---|
| `unstakeDelaySec` | `uint32` |  |

#### `agentIdentityRegistry()`

`0xde5c62a6` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `agentReputationRegistry()`

`0x4382885d` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `APNTS_TOKEN_TIMELOCK()`

`0xddd595ca` · view · access: —

> Window between queueing an `setAPNTsToken` change and being         allowed to execute it. Owner can cancel any time during this         window. Picked to give all integrators (operators, SDKs,         off-chain monitors) at least one weekly review cycle to react.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `APNTS_TOKEN()`

`0x74f053c4` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `aPNTsPriceUSD()`

`0x594a6f23` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `applyBLSAggregator()`

`0xa0c5018b` · nonpayable · access: onlyOwner

#### `BLS_AGGREGATOR()`

`0xc06f58e8` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `cachedPrice()`

`0xf60fdcb3` · view · access: —

| returns | type | description |
|---|---|---|
| `price` | `int256` |  |
| `updatedAt` | `uint256` |  |
| `roundId` | `uint80` |  |
| `decimals` | `uint8` |  |

#### `cancelAPNTsTokenChange()`

`0x1d2282c9` · nonpayable · access: onlyOwner

> Abort a queued APNTS_TOKEN swap before it executes.

#### `cancelEmergencyPrice()`

`0x0c883112` · nonpayable · access: onlyOwner

> Cancel a queued emergency price. Useful when the multisig         realises the queued value is wrong before timelock elapses.

#### `clearPendingDebt(address token, address user)`

`0x5d2e7e50` · nonpayable · access: onlyOwner

> Admin function to clear stuck pending debt (escape hatch)

*@dev* Use when accumulated debt exceeds MAX_SINGLE_TX_LIMIT or token is unreachable

| param | type | description |
|---|---|---|
| `token` | `address` | The xPNTs token address |
| `user` | `address` | The user address |

#### `configureOperator(address xPNTsToken, address _opTreasury)`

`0x5c7c4b5f` · nonpayable · access: —

*@dev* Registers msg.sender as an operator with the given xPNTs token; reverts if token not issued by the wired factory.

| param | type | description |
|---|---|---|
| `xPNTsToken` | `address` |  |
| `_opTreasury` | `address` |  |

#### `deposit()`

`0xd0e30db0` · payable · access: nonReentrant

#### `deposit(uint256 amount)`

`0xb6b55f25` · nonpayable · access: nonReentrant

> Deposit xPNTs tokens from msg.sender into their own operator balance.

| param | type | description |
|---|---|---|
| `amount` | `uint256` |  |

#### `depositFor(address targetOperator, uint256 amount)`

`0x2f4f21e2` · nonpayable · access: nonReentrant

> Deposit xPNTs tokens on behalf of a specific operator address.

| param | type | description |
|---|---|---|
| `targetOperator` | `address` |  |
| `amount` | `uint256` |  |

#### `dryRunValidation((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, uint256 maxCost)`

`0x17a18778` · view · access: —

> P0-15 (J2-BLOCKER-1): pure-view diagnostic mirror of         validatePaymasterUserOp. Bundlers / SDKs / dApps call this         off-chain (eth_call) before submitting a UserOperation to         distinguish the 8 distinct rejection paths that         validatePaymasterUserOp returns as an opaque SIG_FAILURE.

*@dev* Mirrors the main path order; intentionally does NOT mutate         storage or emit events (would brick ERC-7562 compliance and         is impossible from a `view` anyway). Mirrors STALE_PRICE         using the same comparison the main path delegates to         EntryPoint via `validUntil` — i.e., a price is stale when         `block.timestamp > cachedPrice.updatedAt + priceStalenessThreshold`.MERGE DEPENDENCY: This function must be deployed together with P0-16      (future-timestamp guard on cache writes). Without P0-16, dryRunValidation      may return ok=true for a future-timestamp cache, while the actual      validatePaymasterUserOp would revert after P0-16 is deployed.

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` | The UserOperation to dry-run. |
| `maxCost` | `uint256` | Same maxCost EntryPoint will pass to validation. |

| returns | type | description |
|---|---|---|
| `ok` | `bool` | True if validation would pass. |
| `reasonCode` | `bytes32` | Zero when ok==true, otherwise one of the                     `DRYRUN_*` constants explaining why. |

#### `EMERGENCY_TIMELOCK()`

`0x60d7442b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `emergencyActivatedAt()`

`0x3d63f215` · view · access: —

> Timestamp at which EMERGENCY mode was first activated (i.e. first         `executeEmergencyPrice` call after a CHAINLINK→EMERGENCY transition).         Cleared to 0 on Chainlink recovery. Used to enforce EMERGENCY_EXPIRY.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `emergencyPendingPrice()`

`0x34fde76a` · view · access: —

> Pending emergency price (8 decimals, same scale as Chainlink).

| returns | type | description |
|---|---|---|
| `_0` | `int256` |  |

#### `emergencyQueuedAt()`

`0x75e09b51` · view · access: —

> Timestamp at which `emergencySetPrice` was last called; 0 if none queued.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `emergencySetPrice(int256 newPrice)`

`0x96ea1e38` · nonpayable · access: onlyOwner

> Queue an emergency price update. Only honored when Chainlink         is stale and the new price stays within ±20% of the last         cached price; eligible for execution after a 1-hour timelock.

*@dev* P0-10 (D8): pre-fix the owner break-glass path inside         `updatePriceDVT` skipped the deviation check whenever Chainlink         was unavailable, leaving a compromised owner free to write         any price. The new path enforces:           1. Chainlink must actually be stale (otherwise normal              `updatePrice` should be used);           2. New price within ±20% of `cachedPrice.price`;           3. 1-hour timelock so off-chain monitors can flag the queue              event before it lands.

| param | type | description |
|---|---|---|
| `newPrice` | `int256` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The EntryPoint contract (immutable for gas savings on hot path)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `ETH_USD_PRICE_FEED()`

`0xb0f0abe9` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `executeAPNTsTokenChange()`

`0x84450c3d` · nonpayable · access: onlyOwner

> Apply a previously queued APNTS_TOKEN swap.

*@dev* Requires the timelock to have elapsed AND the contract to be         drained of operator-tracked balance and protocol revenue —         the same balance-zero invariant the audit recommended,         enforced at execute-time so operators can decide when to         drain rather than blocking the queue itself.         Intentionally owner-only: unlike OZ TimelockController's         permissionless execute, token migration is sensitive enough         to require explicit owner confirmation. The owner can effectively         cancel any time before calling this function simply by not         calling it, or by calling cancelAPNTsTokenChange() to reset the         queue. Third-party execution is not allowed because it would         remove the owner's final veto after the timelock expires.

#### `executeEmergencyPrice()`

`0xdc61ae90` · nonpayable · access: —

> Apply a previously queued emergency price.

*@dev* Permissionless after the timelock — anyone can land the price,         not just the owner. The protective gates already ran inside         `emergencySetPrice` (Chainlink stale, ±20% band).Permissionless: any address may execute after the 1-hour timelock expires.      This mirrors the OZ TimelockController liveness pattern — the ±20% deviation      cap limits manipulation even if an untrusted party triggers execution.

#### `executeSlashWithBLS(address operator, uint8 level, bytes proof)`

`0x079d2d42` · nonpayable · access: —

> Execute slash triggered by BLS consensus (DVT Module only)

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `level` | `uint8` |  |
| `proof` | `bytes` |  |

#### `facilitatorEarnings(address arg0, address arg1)`

`0xef842a46` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `facilitatorFeeBPS()`

`0xbac256d6` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getAvailableCredit(address user, address token)`

`0xeafe74b5` · view · access: —

> Get operator credit limit for a user

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `token` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getDeposit()`

`0xc399ec88` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getEffectiveFacilitatorFee(address operator)`

`0x8670d78d` · view · access: —

> P1-39: Returns the effective facilitator fee for an operator.

*@dev* Per-operator override takes precedence over the global default.

| param | type | description |
|---|---|---|
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getLatestSlash(address operator)`

`0xc1d9cb08` · view · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `(uint256,uint256,uint256,string,uint8)` |  |

#### `getSlashCount(address operator)`

`0x66c36875` · view · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getSlashHistory(address operator)`

`0xa134d63a` · view · access: —

| param | type | description |
|---|---|---|
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `(uint256,uint256,uint256,string,uint8)[]` |  |

#### `initialize(address _owner, address _apntsToken, address _protocolTreasury, uint256 _priceStalenessThreshold)`

`0xcf756fdf` · nonpayable · access: initializer

> Initialize the UUPS proxy state

| param | type | description |
|---|---|---|
| `_owner` | `address` | Contract owner |
| `_apntsToken` | `address` | aPNTs token address |
| `_protocolTreasury` | `address` | Treasury address for protocol fees |
| `_priceStalenessThreshold` | `uint256` | Oracle staleness threshold in seconds |

#### `isChainlinkStale()`

`0x8e0d8ed9` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isEligibleForSponsorship(address user)`

`0x6a16e22d` · view · access: —

> V5.3: Dual-channel eligibility — SBT holder OR registered ERC-8004 agent

| param | type | description |
|---|---|---|
| `user` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isRegisteredAgent(address account)`

`0xe21b38d2` · view · access: —

> Check if an address is a registered ERC-8004 agent

*@dev* Called inside validatePaymasterUserOp. ERC-7562 §3.2 permits this      external call because isRegisteredAgent(account) reads only      sender-associated storage, satisfying the "associated storage" rule.      Using the dedicated isRegisteredAgent() rather than generic balanceOf()      ensures only ERC-8004 compliant registries qualify — not arbitrary ERC-721s.      try/catch degrades gracefully if the registry is self-destructed or buggy.

| param | type | description |
|---|---|---|
| `account` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `onTransferReceived(address arg0, address from, uint256 value, bytes arg3)`

`0x88a7ca5c` · nonpayable · access: nonReentrant

> Handle ERC1363 transferAndCall (Push Mode)

*@dev* Safe deposit mechanism for tokens blocking transferFrom

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `from` | `address` |  |
| `value` | `uint256` |  |
| `arg3` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes4` |  |

#### `operatorFacilitatorFees(address arg0)`

`0x928624e7` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `operators(address arg0)`

`0x13e7c9d8` · view · access: —

> Get operator configuration

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `aPNTsBalance` | `uint128` |  |
| `isConfigured` | `bool` |  |
| `isPaused` | `bool` |  |
| `xPNTsToken` | `address` |  |
| `reputation` | `uint32` |  |
| `minTxInterval` | `uint48` |  |
| `treasury` | `address` |  |
| `totalSpent` | `uint256` |  |
| `totalTxSponsored` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingAPNTsToken()`

`0x60a9139b` · view · access: —

> Pending APNTS_TOKEN swap; address(0) when none queued.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingAPNTsTokenEta()`

`0xbb2ddb27` · view · access: —

> Earliest timestamp at which `executeAPNTsTokenChange` may run.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `pendingBLSAgg()`

`0xb7b76cbe` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingBLSAggEta()`

`0xfe719e2f` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint48` |  |

#### `pendingDebts(address arg0, address arg1)`

`0x7b707185` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)`

`0x7c627b21` · nonpayable · access: onlyEntryPoint, nonReentrant

> Post-operation handler. Must verify sender is the entryPoint.

| param | type | description |
|---|---|---|
| `mode` | `uint8` | - Enum with the following options:                        opSucceeded - User operation succeeded.                        opReverted  - User op reverted. The paymaster still has to pay for gas.                        postOpReverted - never passed in a call to postOp(). |
| `context` | `bytes` | - The context value returned by validatePaymasterUserOp |
| `actualGasCost` | `uint256` | - Actual gas used so far (without this postOp call). |
| `actualUserOpFeePerGas` | `uint256` | - the gas price this UserOp pays. This value is based on the UserOp's maxFeePerGas                        and maxPriorityFee (and basefee)                        It is not the same as tx.gasprice, which is what the bundler pays. |

#### `priceMode()`

`0x07615815` · view · access: —

> 0 = CHAINLINK (normal), 1 = EMERGENCY (owner override active).

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `priceStalenessThreshold()`

`0xbd111870` · view · access: —

> Price staleness threshold (seconds)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `priceValidUntil()`

`0x82309dd8` · view · access: —

> Returns the timestamp after which the cached price is considered stale.

*@dev* Returns 0 if price has never been updated. Use to check freshness off-chain.

| returns | type | description |
|---|---|---|
| `_0` | `uint48` |  |

#### `protocolFeeBPS()`

`0x96daa322` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `protocolRevenue()`

`0x7af3816c` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `proxiableUUID()`

`0x52d1902d` · view · access: —

*@dev* Implementation of the ERC1822 {proxiableUUID} function. This returns the storage slot used by the implementation. It is used to validate the implementation's compatibility when performing an upgrade. IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `queueBLSAggregator(address _bls)`

`0xb54a8fca` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_bls` | `address` |  |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `retryPendingDebt(address token, address user, uint256 amount)`

`0x8041c94a` · nonpayable · access: onlyOwner, nonReentrant

> Retry recording a pending debt that failed during postOp.

*@dev* H-01: takes an explicit `amount` so a pending balance larger than the         token's per-tx limit (`maxSingleTxLimit`) can be drained in chunks —         call repeatedly with `amount <= maxSingleTxLimit` until empty. Previously         it always retried the full balance, which reverted (and stayed stuck)         whenever the accumulated debt exceeded that limit. The remainder stays in         `pendingDebts` for the next call. Pass `amount == 0` to attempt the full         balance in one shot (works when it is within the limit).

| param | type | description |
|---|---|---|
| `token` | `address` | The xPNTs token address |
| `user` | `address` | The user address |
| `amount` | `uint256` | aPNTs to record this call; clamped to the pending balance. |

#### `sbtHolders(address arg0)`

`0xf7e8cb0d` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `setAgentRegistries(address _identity, address _reputation)`

`0x6a4b23b1` · nonpayable · access: onlyOwner

> Set ERC-8004 agent registries (Owner only)

*@dev* ERC-7562 constraint: _identity is called via isRegisteredAgent(sender) inside      validatePaymasterUserOp. The contract MUST be ERC-7562 compliant:      (1) no banned opcodes (TIMESTAMP, NUMBER, BLOCKHASH, ORIGIN, etc.),      (2) isRegisteredAgent() reads only sender-associated storage slots.      Requires IAgentIdentityRegistry.isRegisteredAgent() — generic ERC-721s      are NOT accepted since any NFT holder would qualify as an agent.      Non-compliant registries cause bundlers to reject all agent-sponsored      UserOps. Pass address(0) to disable agent sponsorship (SBT-only mode).

| param | type | description |
|---|---|---|
| `_identity` | `address` |  |
| `_reputation` | `address` |  |

#### `setAPNTSPrice(uint256 newPrice)`

`0xec2123f1` · nonpayable · access: onlyOwner

> Set the APNTS Price in USD (Owner Only)

*@dev* P0-11 (B2-N3): pre-fix the only check was `newPrice != 0`. Owner      could move the unit scale arbitrarily — combined with the lack of      timelock, a single mis-typed multisig call could distort the cost      basis for every operator at once. Inline bounds:      - absolute MIN/MAX: prevents nonsense magnitudes (e.g., off-by-1e18)      - ±10% per-tx delta vs current price: bounds blast of mis-clicks      - delta check skipped on first set (oldPrice == 0)      Three setters across SP / xPNTs / V4 PaymasterBase each have their      own MIN/MAX/DELTA tuned to the price they hold (different units),      so the implementations are inline rather than a shared mixin.Price-path independence: the ±10% delta cap enforced here is      independent of the break-glass ±20% cap in `emergencySetPrice`.      The two paths are separate entry points that operate on different      storage (`aPNTsPriceUSD` vs `cachedPrice`); neither can be called      through the other, so a caller cannot exploit one path to bypass      the deviation limit of the other.

| param | type | description |
|---|---|---|
| `newPrice` | `uint256` |  |

#### `setAPNTsToken(address newAPNTsToken)`

`0xd20727d7` · nonpayable · access: onlyOwner

> Queue a new APNTS_TOKEN. Cannot take effect until         `pendingAPNTsTokenEta` and only when both `totalTrackedBalance`         and `protocolRevenue` are within PROTOCOL_REVENUE_BUFFER (otherwise         existing operator deposits would be stranded under the new token's         accounting).

*@dev* P0-9 (B2-N1): owner can cancel within the window via         `cancelAPNTsTokenChange`. Re-queueing a change refreshes the         timer (intentional — allows the owner to abort and restart).

| param | type | description |
|---|---|---|
| `newAPNTsToken` | `address` |  |

#### `setFacilitatorFeeBPS(uint256 _fee)`

`0x2540c471` · nonpayable · access: onlyOwner

> Set default facilitator fee BPS (Owner only)

| param | type | description |
|---|---|---|
| `_fee` | `uint256` |  |

#### `setOperatorFacilitatorFee(address operator, uint256 _fee)`

`0xc50cff87` · nonpayable · access: onlyOwner

> Set per-operator facilitator fee override (Owner only)

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `_fee` | `uint256` |  |

#### `setOperatorLimits(uint48 _minTxInterval)`

`0xfc347007` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_minTxInterval` | `uint48` |  |

#### `setOperatorPaused(address operator, bool paused)`

`0xe8ade1a9` · nonpayable · access: onlyOwner

> Pause/Unpause an operator (Owner Only)

*@dev* Used for security emergency stops

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `paused` | `bool` |  |

#### `setProtocolFee(uint256 newFeeBPS)`

`0x787dce3d` · nonpayable · access: onlyOwner

> Set the protocol fee basis points (Owner Only)

| param | type | description |
|---|---|---|
| `newFeeBPS` | `uint256` |  |

#### `settleX402Payment(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validAfter, uint256 validBefore, bytes32 salt, bytes signature)`

`0xf3a729da` · nonpayable · access: nonReentrant

> Settle x402 payment via EIP-3009 receiveWithAuthorization (USDC native path)

*@dev* C-03 + M-1: both the final recipient `to` AND the payer-approved fee cap         `maxFee` are bound into the EIP-3009 nonce         (`nonce = keccak256(to, maxFee, salt)`). The payer signs the EIP-3009         authorization over that nonce, so an operator that swaps `to` OR raises         `maxFee` produces a different nonce and the EIP-3009 signature no longer         recovers `from` — the transfer reverts. This reuses the payer's existing         token-level signature; no second signature. Without the `maxFee` binding the         payer's EIP-3009 signature only authorizes moving `amount` and places no cap         on the operator's facilitator fee (up to MAX_FACILITATOR_FEE), which the         payer never consented to (M-1).M-1: the path assumes the contract receives exactly `amount`. A fee-on-transfer         / deflationary asset delivers less, so paying out `amount - fee` would overpay         `to` from other settlements' reserves. We measure the actual delta and revert         if it is short. EIP-3009 stablecoins (USDC) are not deflationary, so this only         rejects assets that violate the path's amount==received assumption.M-1 (front-run grief): we use `receiveWithAuthorization`, NOT         `transferWithAuthorization`. The EIP-3009 spec requires the token to enforce         `msg.sender == to` for the receive variant, so only this contract (the `to`)         can submit the authorization. With the transfer variant, anyone who observes         the payer's signature could call the token directly to pull `amount` into the         SuperPaymaster outside of a settlement, burning the token-side nonce and         leaving the funds stranded (the real settle would then revert). The receive         variant closes that grief vector. EIP-3009's two variants share a nonce         namespace but sign distinct typehashes (Transfer- vs ReceiveWithAuthorization);         since the payer signs ONLY the receive typehash, the same signature cannot be         replayed against `transferWithAuthorization` to burn the nonce (recovery would         yield a different signer), so both nonce-burning paths are closed.settlementId uses abi.encode (fixed-size fields) for a collision-free id.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `asset` | `address` |  |
| `amount` | `uint256` |  |
| `maxFee` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `salt` | `bytes32` |  |
| `signature` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `settlementId` | `bytes32` |  |

#### `settleX402PaymentDirect(address from, address to, address asset, uint256 amount, uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes signature)`

`0x7344209c` · nonpayable · access: nonReentrant

> Settle x402 payment via direct transferFrom (xPNTs only)

*@dev* Direct path is restricted to xPNTs tokens registered in         `xpntsFactory` AND to facilitators explicitly approved by the         community that owns the xPNTs. Without these gates:         - any ERC20 the payer ever did `approve(facilitator, MAX)` on           (e.g. USDC for x402 standard payments) could be drained by           a compromised facilitator (xPNTs carry an in-contract           firewall + per-tx cap; arbitrary ERC20s do not);         - any single global facilitator compromise would blast across           every community's xPNTs.         For non-xPNTs settlement use `settleX402Payment` (EIP-3009).settlementId uses abi.encode (not encodePacked), matching the         x402NonceKey encoding to avoid hash-collision with variable-length types.P0-12a: enforce `xpntsFactory.isXPNTs(asset)` gate.P0-12b (D4): enforce community-side `approvedFacilitators`         whitelist on the xPNTs token. Community owner toggles via         `xPNTsToken.add/removeApprovedFacilitator`. AAStar's default         facilitator is NOT auto-approved at deploy — each community         decides explicitly.Nonce and asset whitelist: _validateX402AndComputeFee writes the         nonce before the isXPNTs check executes. However, if the call         reverts (e.g. InvalidXPNTsToken), EVM revert semantics roll back         the nonce write — so the nonce is NOT consumed on failure.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `asset` | `address` |  |
| `amount` | `uint256` |  |
| `maxFee` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `signature` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `settlementId` | `bytes32` |  |

#### `setTreasury(address _treasury)`

`0xf0f44260` · nonpayable · access: onlyOwner

> Set the protocol treasury address (Owner Only)

| param | type | description |
|---|---|---|
| `_treasury` | `address` |  |

#### `setXPNTsFactory(address _factory)`

`0x58a2570a` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_factory` | `address` |  |

#### `slashHistory(address arg0, uint256 arg1)`

`0x8e580213` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `timestamp` | `uint256` |  |
| `amount` | `uint256` |  |
| `reputationLoss` | `uint256` |  |
| `reason` | `string` |  |
| `level` | `uint8` |  |

#### `slashOperator(address operator, uint8 level, uint256 penaltyAmount, string reason)`

`0xbfa5a1eb` · nonpayable · access: onlyOwner

> Slash an operator (Admin/Governance only)

*@dev* Reduces reputation and optionally pauses operator

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `level` | `uint8` |  |
| `penaltyAmount` | `uint256` |  |
| `reason` | `string` |  |

#### `totalTrackedBalance()`

`0x61ad446e` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `treasury()`

`0x61d027b3` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `unlockStake()`

`0xbb9fe6bf` · nonpayable · access: —

#### `updateBlockedStatus(address operator, address[] users, bool[] statuses)`

`0x5f4cd4fe` · nonpayable · access: —

> Batch update blocked status for users (Called by Registry via DVT)

*@dev* Allows DVT to sync credit-exhausted users to Paymaster blacklist

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `users` | `address[]` |  |
| `statuses` | `bool[]` |  |

#### `updatePrice()`

`0x673a7e28` · nonpayable · access: —

> Update price cache from Chainlink oracle (keeper-callable).

*@dev* No future-timestamp guard is needed on this path: `updatedAt` is      read directly from a validated Chainlink response, not supplied by      an untrusted caller. Chainlink nodes always set `updatedAt` to the      block timestamp of the round, which is always <= block.timestamp at      the time of the call. The existing staleness check      (`updatedAt < block.timestamp - priceStalenessThreshold`) already      rejects data that is too old; a Chainlink answer with a future      `updatedAt` is practically impossible (it would require a Chainlink      node to report a timestamp ahead of on-chain time) and would be      caught by the staleness check inverting direction. Contrast with      `updatePriceDVT`, where `updatedAt` is caller-supplied and      therefore requires an explicit future-timestamp guard (P0-16).

#### `updatePriceDVT(int256 price, uint256 updatedAt, bytes proof, uint8 chainlinkRecovered)`

`0x53afb8be` · nonpayable · access: —

> Update price via DVT/BLS consensus (Chainlink fallback)

*@dev* Verifies BLS proof from DVT validators, with ±20% deviation check against Chainlink

| param | type | description |
|---|---|---|
| `price` | `int256` | New ETH/USD price (8 decimals) |
| `updatedAt` | `uint256` | Timestamp of price update |
| `proof` | `bytes` | BLS aggregated proof from DVT validators |
| `chainlinkRecovered` | `uint8` | 0 = Chainlink feed still unavailable (price-only update);                            1 = Chainlink feed has recovered — clears priceMode to 0                                and resets emergencyActivatedAt. |

#### `updateReputation(address operator, uint256 newScore)`

`0xf5c91a08` · nonpayable · access: onlyOwner

> Update Operator Reputation (External Credit Manager)

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `newScore` | `uint256` |  |

#### `updateSBTStatus(address user, bool status)`

`0xa3970ae6` · nonpayable · access: —

> Update SBT holder status (Called by Registry)

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `status` | `bool` |  |

#### `UPGRADE_INTERFACE_VERSION()`

`0xad3cb1cc` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `upgradeToAndCall(address newImplementation, bytes data)`

`0x4f1ef286` · payable · access: —

*@dev* Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call encoded in `data`. Calls {_authorizeUpgrade}. Emits an {Upgraded} event.

| param | type | description |
|---|---|---|
| `newImplementation` | `address` |  |
| `data` | `bytes` |  |

#### `userOpState(address arg0, address arg1)`

`0x6640431f` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `lastTimestamp` | `uint48` |  |
| `isBlocked` | `bool` |  |

#### `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 userOpHash, uint256 maxCost)`

`0x52b7512c` · nonpayable · access: onlyEntryPoint, nonReentrant

> Payment validation: check if paymaster agrees to pay. Must verify sender is the entryPoint. Revert to reject this request. Note that bundlers will reject this method if it changes the state, unless the paymaster is trusted (whitelisted). The paymaster pre-pays using its deposit, and receive back a refund after the postOp method returns.

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` | - The user operation. |
| `userOpHash` | `bytes32` | - Hash of the user's request data. |
| `maxCost` | `uint256` | - The maximum cost of this transaction (based on maximum gas and gas price from userOp). |

| returns | type | description |
|---|---|---|
| `context` | `bytes` | - Value to send to a postOp. Zero length to signify postOp is not required. |
| `validationData` | `uint256` | - Signature and time-range of this operation, encoded the same as the return                          value of validateUserOperation.                          <20-byte> sigAuthorizer - 0 for valid signature, 1 to mark signature failure,                                                    other values are invalid for paymaster.                          <6-byte> validUntil - last timestamp this operation is valid. 0 for "indefinite"                          <6-byte> validAfter - first timestamp this operation is valid                          Note that the validation code cannot use block.timestamp (or block.number) directly. |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

#### `withdraw(uint256 amount)`

`0x2e1a7d4d` · nonpayable · access: nonReentrant

> Withdraw aPNTs

| param | type | description |
|---|---|---|
| `amount` | `uint256` |  |

#### `withdrawFacilitatorEarnings(address asset)`

`0xd4c38f52` · nonpayable · access: nonReentrant

> Withdraw accumulated facilitator earnings

| param | type | description |
|---|---|---|
| `asset` | `address` |  |

#### `withdrawProtocolRevenue(address to, uint256 amount)`

`0xa4b5328f` · nonpayable · access: onlyOwner, nonReentrant

> Withdraw accumulated Protocol Revenue

| param | type | description |
|---|---|---|
| `to` | `address` | Address to receive funds (usually treasury) |
| `amount` | `uint256` | Amount of aPNTs to withdraw |

#### `withdrawStake(address to)`

`0xc23a5cea` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `to` | `address` |  |

#### `withdrawTo(address to, uint256 amount)`

`0x205c2878` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

#### `x402NonceKey(address asset, address from, bytes32 nonce)`

`0x761cda33` · pure · access: —

> Compose the per-(asset, from, nonce) replay-protection key.

*@dev* P0-13: must match exactly what the EIP-3009 / direct callers         submit on-chain. Keep this function `pure` so off-chain SDKs can         mirror the encoding via the contract ABI.

| param | type | description |
|---|---|---|
| `asset` | `address` |  |
| `from` | `address` |  |
| `nonce` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `x402SettlementNonces(bytes32 arg0)`

`0x4ee1a3d6` · view · access: —

> x402 settlement nonces, keyed by keccak256(asset, from, nonce).

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `xpntsFactory()`

`0x6d8a4aff` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

### Events

| topic0 | event |
|---|---|
| `0x92f63be5e4bfac76f996bbbee86c4933f30141307811e42d6977a697dd8fc3ec` | `AgentRegistriesUpdated(address,address)` |
| `0xfcc60d1b1dedb59d33b8eef97db5a70c8f8f8523c70d6a027dbf676f1290f8d2` | `APNTsPriceUpdated(uint256,uint256)` |
| `0xde82ad51cc1336e141528846e966b9e7f7ae89a78ebb71d1f0da0d851592d8ee` | `APNTsTokenChangeCancelled(address)` |
| `0xbbb759660e3239a80c3b3a0326287b69c8a5388b2ba43876c6b91c7c85f21fb8` | `APNTsTokenChangeExecuted(address,address,uint256)` |
| `0x98f60c65a2b39c6b97ac2ab59944af0f43d99c0d1756339e5c607fd64341971c` | `APNTsTokenChangeQueued(address,uint256)` |
| `0x75f4cc3f3f70100dc11e396f47f8af2dec5cf7ec94e06062222be779cf2f3dec` | `APNTsTokenUpdated(address,address)` |
| `0x0b969f7dbdbaad518bf93d6f72458e8fd633fe345297219a90f56b035d14468d` | `BLSAggregatorQueued(address,uint48)` |
| `0x019f532f6e08ee8944dc2e7ac40f3c97ad4a20618aee847ddf7c502821c7dad4` | `BLSAggregatorUpdated(address,address)` |
| `0x8d05946ad7acf1695cdb2c1c7b76b11a907b33e5224f086eea17d6a23841e17f` | `DebtRecordFailed(address,address,uint256)` |
| `0xd1cdd29a2fc16e6ed81266a11c8f7f06897e72e22d1bb9ccf34d63c3583d5df3` | `EmergencyPriceCancelled(int256)` |
| `0xfb96594f297e98363f469f68dba1862f6b4e6dbe060a9fd971f41087b2bb2106` | `EmergencyPriceExecuted(int256)` |
| `0x028dfa1d2bc951d60682384a066c9424c3829ea5f25cb00a5f659caed927faea` | `EmergencyPriceQueued(int256,uint256)` |
| `0xdd3840d6dd5c33bfa3b3743f47978de59805ce10f5170e1659be2936e489d73e` | `FacilitatorEarningsWithdrawn(address,address,uint256)` |
| `0x9b6bf5a61deb3c460999ea46c3ff444018a6f424eb8807d5e7e7ca031461cb98` | `FacilitatorFeeUpdated(uint256,uint256)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0x823c9466affb5a8646bc5f7e6304f72a4622cc01af819ec2f51b1130a725c6d1` | `OperatorConfigured(address,address,address)` |
| `0x06653c045d0a3144153a51ac6909baae43b8d5b67184cb74e988b72858727fe4` | `OperatorDeposited(address,uint256)` |
| `0x4419a541734858dec04cd4ea31aff7b399a0b82dc61f30cc777c1907dc8102ed` | `OperatorMinTxIntervalUpdated(address,uint48)` |
| `0xc5437eb8dd091f69800961953f2bb0bc16ae1ff2d3e52caa96796db65f8271da` | `OperatorPaused(address)` |
| `0xa7503227727e36abb7f0ecf24f626347ccc20233c48c554d49d7d2077a1a3040` | `OperatorSlashed(address,uint256,uint8)` |
| `0xae02c1bd695006b6d891af37fdeefea45a10ebcc17071e3471787db4f1772885` | `OperatorUnpaused(address)` |
| `0x4eea589c35918e3c4d8e0371a062a1d544e41d78fb522381678923b9cd6e6dfa` | `OperatorWithdrawn(address,uint256)` |
| `0x190405c3325ce607eef93c6240d9728b865e09aa174052e80e380f33d165c4f4` | `OracleFallbackTriggered(uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xe4ddb9696b79889a2b0002aa61f703666d072c319c0694d71624728605bdd287` | `PendingDebtCleared(address,address,uint256)` |
| `0x84b561bfeda3b329970b08af25d20086abe657da83a1dbd00fdfaad913e8cfed` | `PendingDebtRetried(address,address,uint256)` |
| `0x5e5763e2a601dbb21ceae7f64e18f3d572378b373daa8d75a325f22f377f0ecb` | `PriceModeChanged(uint8,uint8)` |
| `0xdb6fb3cf4cc5fb760bcd63b958a53b2396776dff32c063188e864296541e76bd` | `PriceUpdated(int256,uint256)` |
| `0xb404cac19fb1cbeff98d325795b08886e3cd8fe8cb1a2f193aac66f13fb239c3` | `ProtocolFeeUpdated(uint256,uint256)` |
| `0x418c06850785ce4239177091a96c1757ba1d5ba22df98a4cf818e1510fa028cd` | `ProtocolRevenueUnderflow(address,uint256,uint256)` |
| `0xf7595c4fd7fa675e456dd9520ac8266c06d237d52900fc573bccc85b7c177c9e` | `ProtocolRevenueWithdrawn(address,uint256)` |
| `0xfc577563f1b9a0461e24abef1e1fcc0d33d3d881f20b5df6dda59de4aae2c821` | `ReputationUpdated(address,uint256)` |
| `0xa49f25e6b37dc7492af788d36761dc1b25f8fb6dcc448fb5637dc828725f0d88` | `SlashExecutedWithProof(address,uint8,uint256,bytes32,uint256)` |
| `0xcde7e91a718e2439d8ff2a679ad52713e82a37b72622fb530c8c41039fdd5bf0` | `TransactionSponsored(address,address,uint256,uint256)` |
| `0x4ab5be82436d353e61ca18726e984e561f5c1cc7c6d38b29d2553c790434705a` | `TreasuryUpdated(address,address)` |
| `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b` | `Upgraded(address)` |
| `0x272958aacfbf07577da4ede62cc7d612dfb0881c6489c961988ef59378d7709f` | `UserBlockedStatusUpdated(address,address,bool)` |
| `0xd2d5a1362bcd0d05f9c4cdcf180554d9198405ba5a938a59bf2ae807acf90eba` | `UserReputationAccrued(address,uint256)` |
| `0xf0131e6cc0fc7174d6c29a5082ba7a09d8f2356d5fdd89e02d323f1a66194939` | `ValidationFailed(bytes32,bytes32)` |
| `0xecef7698217b345db7161a8d2ffa4e7109c3ca0fe6e64ca6627ee67be3e818fc` | `X402PaymentSettled(address,address,address,uint256,uint256,bytes32)` |
| `0x05ba7ce38b27f49ba3b81247ac7a13b30021ce3e90f633a2498fa9d1a0957990` | `XPNTsFactoryUpdated(address,address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0xcd786059` | `AddressInsufficientBalance(address)` |
| `0x54ada055` | `AmountExceedsUint128()` |
| `0x4efd1550` | `ChainlinkNotStale()` |
| `0x144f0768` | `DepositNotVerified()` |
| `0x4a1a5610` | `EmergencyExpired()` |
| `0x6b049335` | `EmergencyPriceOutOfRange()` |
| `0x5d2ccdb4` | `EmergencyTimelockNotElapsed()` |
| `0x4c9c8ce3` | `ERC1967InvalidImplementation(address)` |
| `0xb398979f` | `ERC1967NonPayable()` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0xcf479181` | `InsufficientBalance(uint256,uint256)` |
| `0xb4aa8063` | `InsufficientRevenue()` |
| `0xe6c4247b` | `InvalidAddress()` |
| `0xc52a9bd3` | `InvalidConfiguration()` |
| `0x58d620b3` | `InvalidFee()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0x49e27cff` | `InvalidOwner()` |
| `0xf9d36a71` | `InvalidX402Signature()` |
| `0x67cc8b75` | `InvalidXPNTsToken()` |
| `0x227bc153` | `MathOverflowedMulDiv()` |
| `0xa24a1471` | `NoEmergencyPending()` |
| `0x1fb09b80` | `NonceAlreadyUsed()` |
| `0x0d0a552c` | `NoPendingDebt()` |
| `0xe0a1dc31` | `NoSlashHistory()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0xb41b6cb1` | `OracleError()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x5274afe7` | `SafeERC20FailedOperation(address)` |
| `0x82c6707e` | `ScoreExceedsUint32()` |
| `0xbe3963ef` | `SlashCooldown()` |
| `0x82b42900` | `Unauthorized()` |
| `0xe07c8dba` | `UUPSUnauthorizedCallContext()` |
| `0xaa1d49a4` | `UUPSUnsupportedProxiableUUID(bytes32)` |
| `0x760a602d` | `X402AmountMismatch()` |
| `0x483a32fe` | `X402AuthExpired()` |
| `0xfdc8ad38` | `X402FeeExceedsMax()` |

## PaymasterFactory

- **Source:** `contracts/src/paymasters/v4/core/PaymasterFactory.sol`
- **Functions:** 26 · **Events:** 6 · **Errors:** 14
- **Title:** PaymasterFactory
- Factory contract for deploying Paymaster instances using EIP-1167 Minimal Proxy

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x75637505` | `addImplementation(string,address)` | nonpayable | onlyOwner | Add new implementation version |
| `0x1798d482` | `defaultVersion()` | view | — | Current default version |
| `0x64feab64` | `deployPaymaster(string,bytes)` | nonpayable | nonReentrant | Deploy a new Paymaster using minimal proxy pattern |
| `0xad384a9b` | `deployPaymasterDeterministic(string,bytes32,bytes)` | nonpayable | nonReentrant | Deploy Paymaster using deterministic address (CREATE2) |
| `0x6b683896` | `getImplementation(string)` | view | — | Get implementation address by version |
| `0xa87d5a74` | `getOperatorByPaymaster(address)` | view | — | Get operator address by Paymaster |
| `0x41bbe5a8` | `getPaymasterByOperator(address)` | view | — | Get Paymaster address by operator |
| `0x14b1c401` | `getPaymasterCount()` | view | — | Get total number of deployed Paymasters |
| `0xdc2a1472` | `getPaymasterInfo(address)` | view | — | Get Paymaster info |
| `0xd1255313` | `getPaymasterList(uint256,uint256)` | view | — | Get paginated list of deployed Paymasters |
| `0xf3bcebbd` | `hasImplementation(string)` | view | — | Check if implementation exists for version |
| `0x6a189439` | `hasPaymaster(address)` | view | — | Check if operator has deployed Paymaster |
| `0x0618f104` | `implementations(string)` | view | — | Mapping of version string to implementation address |
| `0xce47d467` | `operatorByPaymaster(address)` | view | — | Reverse mapping: Paymaster address to operator |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x6c583e59` | `paymasterByOperator(address)` | view | — | Mapping of operator address to their deployed Paymaster address |
| `0x821ac3fb` | `paymasterList(uint256)` | view | — | List of all deployed Paymaster addresses |
| `0xbde9cb2a` | `predictPaymasterAddress(string,bytes32)` | view | — | Predict deterministic Paymaster address |
| `0x7b103999` | `registry()` | view | — | Optional Registry for role gating (zero = open deployment) |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x85365cbb` | `setDefaultVersion(string)` | nonpayable | onlyOwner | Set default version for deployments |
| `0xa91ee0dc` | `setRegistry(address)` | nonpayable | onlyOwner | Set optional Registry for role gating (owner only; zero address disables gating) |
| `0x0cfb14b0` | `totalDeployed()` | view | — | Total number of deployed Paymasters |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x7857bce9` | `upgradeImplementation(string,address)` | nonpayable | onlyOwner | Upgrade existing implementation version |
| `0x54fd4d50` | `version()` | pure | — | Contract version (semantic versioning) |

### Functions

#### `addImplementation(string _version, address implementation)`

`0x75637505` · nonpayable · access: onlyOwner

> Add new implementation version

| param | type | description |
|---|---|---|
| `_version` | `string` | Version string (e.g., "v1.0", "v2.0") |
| `implementation` | `address` | Implementation contract address |

#### `defaultVersion()`

`0x1798d482` · view · access: —

> Current default version

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `deployPaymaster(string _version, bytes initData)`

`0x64feab64` · nonpayable · access: nonReentrant

> Deploy a new Paymaster using minimal proxy pattern

| param | type | description |
|---|---|---|
| `_version` | `string` | Version of Paymaster implementation to use |
| `initData` | `bytes` | Initialization data for the Paymaster |

| returns | type | description |
|---|---|---|
| `paymaster` | `address` | Address of the newly deployed Paymaster |

#### `deployPaymasterDeterministic(string _version, bytes32 salt, bytes initData)`

`0xad384a9b` · nonpayable · access: nonReentrant

> Deploy Paymaster using deterministic address (CREATE2)

| param | type | description |
|---|---|---|
| `_version` | `string` | Version of Paymaster implementation |
| `salt` | `bytes32` | Salt for deterministic deployment |
| `initData` | `bytes` | Initialization data |

| returns | type | description |
|---|---|---|
| `paymaster` | `address` | Deterministically deployed Paymaster address |

#### `getImplementation(string _version)`

`0x6b683896` · view · access: —

> Get implementation address by version

| param | type | description |
|---|---|---|
| `_version` | `string` | Version string |

| returns | type | description |
|---|---|---|
| `implementation` | `address` | Implementation contract address |

#### `getOperatorByPaymaster(address paymaster)`

`0xa87d5a74` · view · access: —

> Get operator address by Paymaster

| param | type | description |
|---|---|---|
| `paymaster` | `address` | Paymaster address |

| returns | type | description |
|---|---|---|
| `operator` | `address` | Operator address |

#### `getPaymasterByOperator(address operator)`

`0x41bbe5a8` · view · access: —

> Get Paymaster address by operator

| param | type | description |
|---|---|---|
| `operator` | `address` | Operator address |

| returns | type | description |
|---|---|---|
| `paymaster` | `address` | Paymaster address (address(0) if none) |

#### `getPaymasterCount()`

`0x14b1c401` · view · access: —

> Get total number of deployed Paymasters

| returns | type | description |
|---|---|---|
| `count` | `uint256` | Total Paymasters |

#### `getPaymasterInfo(address paymaster)`

`0xdc2a1472` · view · access: —

> Get Paymaster info

| param | type | description |
|---|---|---|
| `paymaster` | `address` | Paymaster address |

| returns | type | description |
|---|---|---|
| `operator` | `address` | Operator address |
| `isValid` | `bool` | True if Paymaster was deployed by this factory |

#### `getPaymasterList(uint256 offset, uint256 limit)`

`0xd1255313` · view · access: —

> Get paginated list of deployed Paymasters

| param | type | description |
|---|---|---|
| `offset` | `uint256` | Start index |
| `limit` | `uint256` | Number of results |

| returns | type | description |
|---|---|---|
| `paymasters` | `address[]` | Array of Paymaster addresses |

#### `hasImplementation(string _version)`

`0xf3bcebbd` · view · access: —

> Check if implementation exists for version

| param | type | description |
|---|---|---|
| `_version` | `string` | Version string |

| returns | type | description |
|---|---|---|
| `exists` | `bool` | True if implementation exists |

#### `hasPaymaster(address operator)`

`0x6a189439` · view · access: —

> Check if operator has deployed Paymaster

| param | type | description |
|---|---|---|
| `operator` | `address` | Operator address |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | hasPaymaster True if operator has Paymaster |

#### `implementations(string arg0)`

`0x0618f104` · view · access: —

> Mapping of version string to implementation address

| param | type | description |
|---|---|---|
| `arg0` | `string` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `operatorByPaymaster(address arg0)`

`0xce47d467` · view · access: —

> Reverse mapping: Paymaster address to operator

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `paymasterByOperator(address arg0)`

`0x6c583e59` · view · access: —

> Mapping of operator address to their deployed Paymaster address

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `paymasterList(uint256 arg0)`

`0x821ac3fb` · view · access: —

> List of all deployed Paymaster addresses

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `predictPaymasterAddress(string _version, bytes32 salt)`

`0xbde9cb2a` · view · access: —

> Predict deterministic Paymaster address

| param | type | description |
|---|---|---|
| `_version` | `string` | Version to use |
| `salt` | `bytes32` | Salt for CREATE2 |

| returns | type | description |
|---|---|---|
| `predicted` | `address` | Predicted Paymaster address |

#### `registry()`

`0x7b103999` · view · access: —

> Optional Registry for role gating (zero = open deployment)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `setDefaultVersion(string _version)`

`0x85365cbb` · nonpayable · access: onlyOwner

> Set default version for deployments

| param | type | description |
|---|---|---|
| `_version` | `string` | Version string |

#### `setRegistry(address _registry)`

`0xa91ee0dc` · nonpayable · access: onlyOwner

> Set optional Registry for role gating (owner only; zero address disables gating)

| param | type | description |
|---|---|---|
| `_registry` | `address` |  |

#### `totalDeployed()`

`0x0cfb14b0` · view · access: —

> Total number of deployed Paymasters

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `upgradeImplementation(string _version, address newImplementation)`

`0x7857bce9` · nonpayable · access: onlyOwner

> Upgrade existing implementation version

*@dev* Does NOT affect already deployed Paymasters (immutable proxies)

| param | type | description |
|---|---|---|
| `_version` | `string` | Version to upgrade |
| `newImplementation` | `address` | New implementation address |

#### `version()`

`0x54fd4d50` · pure · access: —

> Contract version (semantic versioning)

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

### Events

| topic0 | event |
|---|---|
| `0xf2d0bf91625d9d6f0875b7d42914fd44597c078083d98cb3619c009136be9f6a` | `DefaultVersionChanged(string,string)` |
| `0x9aa81ca4174435962ad1571b0a59c4440cf6de4a12ba4ed96d6fdf5d34674278` | `ImplementationAdded(string,address)` |
| `0x2255c4b39068cc7208e9c29b0fc9a3d106b3a41ada38999656d54aa44a6dc9e8` | `ImplementationUpgraded(string,address,address)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xa1ff1ed230517376e0a7481a00b4dfc8f2f2e212bccebd933d567bf5640494c0` | `PaymasterDeployed(address,address,string,uint256)` |
| `0x482b97c53e48ffa324a976e2738053e9aff6eee04d8aac63b10e19411d869b82` | `RegistryUpdated(address,address)` |

### Errors

| selector | error |
|---|---|
| `0xc2f868f4` | `ERC1167FailedCreateClone()` |
| `0xed4fac37` | `ImplementationNotFound(string)` |
| `0x225d0a58` | `InitFailed(bytes)` |
| `0x0c760937` | `InvalidImplementation(address)` |
| `0xf9c42c60` | `InvalidInitData()` |
| `0xbba370d8` | `NotRegisteredCommunity()` |
| `0xe0ffb51e` | `NotRegisteredPaymasterAOA()` |
| `0x69e496ad` | `OperatorAlreadyHasPaymaster(address)` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x4ecf968e` | `OwnerMismatch(address,address)` |
| `0x51b795b8` | `PaymasterNotFound(address)` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0xb94f32dd` | `VersionAlreadyExists(string)` |

## Paymaster

- **Source:** `contracts/src/paymasters/v4/Paymaster.sol`
- **Functions:** 54 · **Events:** 17 · **Errors:** 26
- **Title:** Paymaster
- Paymaster with Registry management capabilities

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xdbcd429c` | `activateInRegistry()` | nonpayable | onlyOwner | Re-list this paymaster in the active discovery listing. |
| `0x4a58db19` | `addDeposit()` | payable | — |  |
| `0x0396cb60` | `addStake(uint32)` | payable | — |  |
| `0xc23f001f` | `balances(address,address)` | view | — | User Internal Balances: User -> Token -> Amount (Deposit-Only Model) |
| `0xce6771c9` | `CACHED_PRICE_DELTA_BPS()` | view | — |  |
| `0x84b863a8` | `CACHED_PRICE_MAX()` | view | — |  |
| `0xc7c6bd2c` | `CACHED_PRICE_MIN()` | view | — | P0-11: bounds for `setCachedPrice` (ETH/USD, 8 decimals).         $100 floor guards the crash-to-zero attack where an owner         could set price=1 making every UserOp appear free. $1M ceiling         rules out off-by-1e8 typos. ±30% per-tx delta reflects ETH         intraday extremes while blocking multi-step manipulation. |
| `0xf60fdcb3` | `cachedPrice()` | view | — | Cached ETH/USD price for validation |
| `0x5dbfc94d` | `calculateCost(uint256,address,bool)` | view | — | External wrapper that respects the Realtime Flag (New Optimization) |
| `0x36f897e7` | `deactivateFromRegistry()` | nonpayable | onlyOwner | Remove this paymaster from the active discovery listing. |
| `0xb3db428b` | `depositFor(address,address,uint256)` | nonpayable | — | Deposit funds for user (Push Model) |
| `0xb0d691fe` | `entryPoint()` | view | — | EntryPoint contract address |
| `0x42f6fb29` | `ethUsdPriceFeed()` | view | — | Chainlink ETH/USD price feedChainlink ETH/USD price feed |
| `0xd3c7c2c7` | `getSupportedTokens()` | view | — | Get all supported token addresses |
| `0xdb110a07` | `getSupportedTokensInfo()` | view | — | Get full info for all supported tokens |
| `0xe77fc7a4` | `initialize(address,address,address,address,uint256,uint256,uint256)` | nonpayable | initializer | Initialize Paymaster (for proxy instances or direct constructor) |
| `0x6f374b0f` | `isActiveInRegistry()` | view | — | True iff this paymaster is in the active discovery listing. |
| `0xa032f4b8` | `isRegistrySet()` | view | — | Check if Registry is set |
| `0x75151b63` | `isTokenSupported(address)` | view | — | Check if a token is supported |
| `0x39788cd9` | `MAX_ETH_USD_PRICE()` | view | — | Maximum acceptable ETH/USD price from oracle ($100,000) |
| `0x3400ba52` | `MAX_GAS_TOKENS()` | view | — | Maximum number of supported GasTokens |
| `0xaa51e015` | `MAX_SBTS()` | view | — | Maximum number of supported SBTs |
| `0x14d90e1b` | `MAX_SERVICE_FEE()` | view | — | Maximum service fee (10%) |
| `0x0879c412` | `maxGasCostCap()` | view | — | Maximum gas cost cap per transaction (in wei) |
| `0x32726684` | `MIN_ETH_USD_PRICE()` | view | — | Minimum acceptable ETH/USD price from oracle ($100) |
| `0xe68b52e7` | `oracleDecimals()` | view | — | Cached oracle decimals to avoid external call in validate |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x8456cb59` | `pause()` | nonpayable | — | Halt sponsorship locally — `whenNotPaused` modifier on         validatePaymasterUserOp will revert all new userOps. |
| `0x5c975abb` | `paused()` | view | — | Emergency pause flag |
| `0x7c627b21` | `postOp(uint8,bytes,uint256,uint256)` | nonpayable | — | PostOp handler with refund logic |
| `0xbd111870` | `priceStalenessThreshold()` | view | — | Price staleness threshold (seconds) |
| `0x7b103999` | `registry()` | view | — | V3 Registry contract (immutable, set at deployment via factory) |
| `0x5fa7b584` | `removeToken(address)` | nonpayable | — | Remove a supported token |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x61d1bc94` | `serviceFeeRate()` | view | — | Service fee rate in basis points (200 = 2%) |
| `0x083e91c4` | `setCachedPrice(uint256,uint48)` | nonpayable | — | Direct Cache Update (Operator/Keeper Pushed Price) |
| `0xc9929dad` | `setMaxGasCostCap(uint256)` | nonpayable | — |  |
| `0x4915a858` | `setPriceStalenessThreshold(uint256)` | nonpayable | — |  |
| `0x9b1d3091` | `setServiceFeeRate(uint256)` | nonpayable | — |  |
| `0x431f63c9` | `setTokenPrice(address,uint256)` | nonpayable | — | Set supported token price (enable or update token) |
| `0xf0f44260` | `setTreasury(address)` | nonpayable | — |  |
| `0x975dd5be` | `TIMESTAMP_GRACE_SECONDS()` | view | — | Grace window for keeper-pushed timestamps (seconds). |
| `0x8ee573ac` | `tokenDecimals(address)` | view | — |  |
| `0x204120bc` | `tokenPrices(address)` | view | — | Token Price in USD (8 decimals) set by Admin/Keeper |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x61d027b3` | `treasury()` | view | — | Treasury address - service provider's collection account |
| `0xbb9fe6bf` | `unlockStake()` | nonpayable | — |  |
| `0x3f4ba83a` | `unpause()` | nonpayable | — |  |
| `0x673a7e28` | `updatePrice()` | nonpayable | — | Update cached price from Oracle (Keeper only) |
| `0x52b7512c` | `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)` | nonpayable | — | Validates paymaster operation and deducts internal balance |
| `0x54fd4d50` | `version()` | pure | — | Contract version |
| `0xf3fef3a3` | `withdraw(address,uint256)` | nonpayable | — | Withdraw funds |
| `0xc23a5cea` | `withdrawStake(address)` | nonpayable | — |  |
| `0x205c2878` | `withdrawTo(address,uint256)` | nonpayable | — |  |

### Functions

#### `activateInRegistry()`

`0xdbcd429c` · nonpayable · access: onlyOwner

> Re-list this paymaster in the active discovery listing.

*@dev* Sets paused=false so validatePaymasterUserOp accepts new UserOps         again and isActiveInRegistry() returns true (assuming the owner         still holds ROLE_PAYMASTER_AOA in Registry).

#### `addDeposit()`

`0x4a58db19` · payable · access: —

#### `addStake(uint32 unstakeDelaySec)`

`0x0396cb60` · payable · access: —

| param | type | description |
|---|---|---|
| `unstakeDelaySec` | `uint32` |  |

#### `balances(address arg0, address arg1)`

`0xc23f001f` · view · access: —

> User Internal Balances: User -> Token -> Amount (Deposit-Only Model)

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_DELTA_BPS()`

`0xce6771c9` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_MAX()`

`0x84b863a8` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_MIN()`

`0xc7c6bd2c` · view · access: —

> P0-11: bounds for `setCachedPrice` (ETH/USD, 8 decimals).         $100 floor guards the crash-to-zero attack where an owner         could set price=1 making every UserOp appear free. $1M ceiling         rules out off-by-1e8 typos. ±30% per-tx delta reflects ETH         intraday extremes while blocking multi-step manipulation.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `cachedPrice()`

`0xf60fdcb3` · view · access: —

> Cached ETH/USD price for validation

| returns | type | description |
|---|---|---|
| `price` | `uint208` |  |
| `updatedAt` | `uint48` |  |

#### `calculateCost(uint256 gasCost, address token, bool useRealtime)`

`0x5dbfc94d` · view · access: —

> External wrapper that respects the Realtime Flag (New Optimization)

| param | type | description |
|---|---|---|
| `gasCost` | `uint256` |  |
| `token` | `address` |  |
| `useRealtime` | `bool` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `deactivateFromRegistry()`

`0x36f897e7` · nonpayable · access: onlyOwner

> Remove this paymaster from the active discovery listing.

*@dev* "deactivate" is a listing notification, NOT an exitRole.         ROLE_PAYMASTER_AOA stays on the operator EOA throughout so the         operator can re-activate later with activateInRegistry().         Pausing the contract is the authoritative "not accepting UserOps"         signal; discovery consumers check !paused AND hasRole(owner).

#### `depositFor(address user, address token, uint256 amount)`

`0xb3db428b` · nonpayable · access: —

> Deposit funds for user (Push Model)

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `token` | `address` |  |
| `amount` | `uint256` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> EntryPoint contract address

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `ethUsdPriceFeed()`

`0x42f6fb29` · view · access: —

> Chainlink ETH/USD price feedChainlink ETH/USD price feed

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getSupportedTokens()`

`0xd3c7c2c7` · view · access: —

> Get all supported token addresses

| returns | type | description |
|---|---|---|
| `_0` | `address[]` |  |

#### `getSupportedTokensInfo()`

`0xdb110a07` · view · access: —

> Get full info for all supported tokens

| returns | type | description |
|---|---|---|
| `tokens` | `address[]` | Array of token addresses |
| `prices` | `uint256[]` | Array of USD prices (8 decimals) |
| `decimalsArr` | `uint8[]` | Array of token decimals |

#### `initialize(address _entryPoint, address _owner, address _treasury, address _ethUsdPriceFeed, uint256 _serviceFeeRate, uint256 _maxGasCostCap, uint256 _priceStalenessThreshold)`

`0xe77fc7a4` · nonpayable · access: initializer

> Initialize Paymaster (for proxy instances or direct constructor)

| param | type | description |
|---|---|---|
| `_entryPoint` | `address` | EntryPoint contract address |
| `_owner` | `address` | Initial owner address |
| `_treasury` | `address` | Treasury address for fee collection |
| `_ethUsdPriceFeed` | `address` | Chainlink ETH/USD price feed address |
| `_serviceFeeRate` | `uint256` | Service fee in basis points |
| `_maxGasCostCap` | `uint256` | Maximum gas cost cap |
| `_priceStalenessThreshold` | `uint256` | Staleness threshold |

#### `isActiveInRegistry()`

`0x6f374b0f` · view · access: —

> True iff this paymaster is in the active discovery listing.

*@dev* Two conditions must both hold:           1. The operator EOA (owner()) still holds ROLE_PAYMASTER_AOA.           2. The paymaster has not been deactivated (paused == false).         ROLE_PAYMASTER_AOA is on the operator EOA, NOT on address(this) —         querying address(this) (the old bug) always returned false.

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isRegistrySet()`

`0xa032f4b8` · view · access: —

> Check if Registry is set

| returns | type | description |
|---|---|---|
| `_0` | `bool` | True if registry address is configured |

#### `isTokenSupported(address token)`

`0x75151b63` · view · access: —

> Check if a token is supported

| param | type | description |
|---|---|---|
| `token` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `MAX_ETH_USD_PRICE()`

`0x39788cd9` · view · access: —

> Maximum acceptable ETH/USD price from oracle ($100,000)

| returns | type | description |
|---|---|---|
| `_0` | `int256` |  |

#### `MAX_GAS_TOKENS()`

`0x3400ba52` · view · access: —

> Maximum number of supported GasTokens

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MAX_SBTS()`

`0xaa51e015` · view · access: —

> Maximum number of supported SBTs

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MAX_SERVICE_FEE()`

`0x14d90e1b` · view · access: —

> Maximum service fee (10%)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `maxGasCostCap()`

`0x0879c412` · view · access: —

> Maximum gas cost cap per transaction (in wei)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MIN_ETH_USD_PRICE()`

`0x32726684` · view · access: —

> Minimum acceptable ETH/USD price from oracle ($100)

| returns | type | description |
|---|---|---|
| `_0` | `int256` |  |

#### `oracleDecimals()`

`0xe68b52e7` · view · access: —

> Cached oracle decimals to avoid external call in validate

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pause()`

`0x8456cb59` · nonpayable · access: —

> Halt sponsorship locally — `whenNotPaused` modifier on         validatePaymasterUserOp will revert all new userOps.

*@dev* The original code shipped `paused`, `whenNotPaused`, and the         Paused/Unpaused events, but no setter — the modifier could         never become true, leaving operators with no on-chain stop.         Combined with P0-5 (Registry exitRole) this gives V4 paymasters         a fast local halt and a coordinated registry-level deactivation.

#### `paused()`

`0x5c975abb` · view · access: —

> Emergency pause flag

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 arg3)`

`0x7c627b21` · nonpayable · access: —

> PostOp handler with refund logic

*@dev* Intentionally NOT guarded by whenNotPaused — UserOps that already      passed validatePaymasterUserOp must be allowed to settle; blocking      postOp would strand the EntryPoint and waste the bundler's gas.      Pause semantics: no new ops (validate blocked) + no withdrawals;      existing in-flight ops complete normally.

| param | type | description |
|---|---|---|
| `mode` | `uint8` |  |
| `context` | `bytes` |  |
| `actualGasCost` | `uint256` |  |
| `arg3` | `uint256` |  |

#### `priceStalenessThreshold()`

`0xbd111870` · view · access: —

> Price staleness threshold (seconds)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `registry()`

`0x7b103999` · view · access: —

> V3 Registry contract (immutable, set at deployment via factory)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `removeToken(address token)`

`0x5fa7b584` · nonpayable · access: —

> Remove a supported token

| param | type | description |
|---|---|---|
| `token` | `address` | ERC20 token address to remove |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `serviceFeeRate()`

`0x61d1bc94` · view · access: —

> Service fee rate in basis points (200 = 2%)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `setCachedPrice(uint256 price, uint48 timestamp)`

`0x083e91c4` · nonpayable · access: —

> Direct Cache Update (Operator/Keeper Pushed Price)

*@dev* P0-16 (Codex B-N1): reject future timestamps. A future `updatedAt`      bypasses staleness checks and underflows the postOp staleness      subtraction in `_postOp`, bricking that path until the cache is      overwritten with a valid (past) timestamp.      A 15-second grace window (TIMESTAMP_GRACE_SECONDS) accommodates the      ~12 s maximum drift between a keeper's wall-clock and block.timestamp,      preventing spurious rejections of honest keepers.P0-11 (B2-N3 / V4): three guards stack on top of the P0-16      future-timestamp check:      - absolute MIN/MAX: prevent $0 / typo / crash-to-zero attacks      - ±30% per-tx delta (vs current cache): limits blast of a        misclick or partially-compromised owner key; skipped when        cachedPrice is uninitialised (first push).

| param | type | description |
|---|---|---|
| `price` | `uint256` | ETH/USD price (8 decimals) |
| `timestamp` | `uint48` | Timestamp of the price |

#### `setMaxGasCostCap(uint256 _maxGasCostCap)`

`0xc9929dad` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_maxGasCostCap` | `uint256` |  |

#### `setPriceStalenessThreshold(uint256 _priceStalenessThreshold)`

`0x4915a858` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_priceStalenessThreshold` | `uint256` |  |

#### `setServiceFeeRate(uint256 _serviceFeeRate)`

`0x9b1d3091` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_serviceFeeRate` | `uint256` |  |

#### `setTokenPrice(address token, uint256 price)`

`0x431f63c9` · nonpayable · access: —

> Set supported token price (enable or update token)

| param | type | description |
|---|---|---|
| `token` | `address` | ERC20 token address |
| `price` | `uint256` | USD price with 8 decimals (e.g. 1e8 = $1.00) |

#### `setTreasury(address _treasury)`

`0xf0f44260` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_treasury` | `address` |  |

#### `TIMESTAMP_GRACE_SECONDS()`

`0x975dd5be` · view · access: —

> Grace window for keeper-pushed timestamps (seconds).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tokenDecimals(address arg0)`

`0x8ee573ac` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `tokenPrices(address arg0)`

`0x204120bc` · view · access: —

> Token Price in USD (8 decimals) set by Admin/Keeper

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `treasury()`

`0x61d027b3` · view · access: —

> Treasury address - service provider's collection account

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `unlockStake()`

`0xbb9fe6bf` · nonpayable · access: —

#### `unpause()`

`0x3f4ba83a` · nonpayable · access: —

#### `updatePrice()`

`0x673a7e28` · nonpayable · access: —

> Update cached price from Oracle (Keeper only)

#### `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 arg1, uint256 maxCost)`

`0x52b7512c` · nonpayable · access: —

> Validates paymaster operation and deducts internal balance

*@dev* Deposit-Only mode: Checks internal balance, NO external calls.

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` |  |
| `arg1` | `bytes32` |  |
| `maxCost` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `context` | `bytes` |  |
| `validationData` | `uint256` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Contract version

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `withdraw(address token, uint256 amount)`

`0xf3fef3a3` · nonpayable · access: —

> Withdraw funds

*@dev* whenNotPaused: during a security incident we must prevent fund      drain while still allowing new deposits (depositFor is unguarded      because adding funds is never dangerous).

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `amount` | `uint256` |  |

#### `withdrawStake(address withdrawAddress)`

`0xc23a5cea` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `withdrawAddress` | `address` |  |

#### `withdrawTo(address withdrawAddress, uint256 amount)`

`0x205c2878` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `withdrawAddress` | `address` |  |
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0xa802e6454d86a21ffa90efd6c93aa893bcf539fea6c1a9c8097879faccc389bb` | `ActivatedInRegistry(address)` |
| `0xca323d32ea3ada728fbc5a470183af7d4cc49a426cb2bdf68847d6e298576f20` | `DeactivatedFromRegistry(address)` |
| `0xf0d0e99cae184d0187b093b48894117462462379674a6e11d89c3fbb618e96b0` | `FundsDeposited(address,address,uint256)` |
| `0xa92ff919b850e4909ab2261d907ef955f11bc1716733a6cbece38d163a69af8a` | `FundsWithdrawn(address,address,uint256)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0x49081791577ea5202d6975e5d6ad3a55a49709b1adf70fbd4fbf4b3ffda6e031` | `MaxGasCostCapUpdated(uint256,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` | `Paused(address)` |
| `0x62544d7f48b11c32334310ebd306b47224fca220163218d4a7264322c52ae073` | `PostOpProcessed(address,address,uint256,uint256,uint256)` |
| `0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838` | `PriceUpdated(uint256,uint256)` |
| `0x2b5186a49160aeb8b14d6c82226402a1645e57be3d6219529ab397ee97413475` | `PriceUpdateFailed()` |
| `0x003b413cf14a67407425bd0b5c065b2de08876554d8489ad7dd4aa95604d280c` | `ServiceFeeUpdated(uint256,uint256)` |
| `0x2cfed7ac4be4a0009ef1af32ea2de149e0122938cb9aa4b3f7df3be6da1055e9` | `StalenessThresholdUpdated(uint256,uint256)` |
| `0xceb40be0a58aa33916c199e469842b614ef313295573c15d82f85cc9d1a89d32` | `TokenPriceUpdated(address,uint256)` |
| `0x4c910b69fe65a61f7531b9c5042b2329ca7179c77290aa7e2eb3afa3c8511fd3` | `TokenRemoved(address)` |
| `0x4ab5be82436d353e61ca18726e984e561f5c1cc7c6d38b29d2553c790434705a` | `TreasuryUpdated(address,address)` |
| `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` | `Unpaused(address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0xcd786059` | `AddressInsufficientBalance(address)` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0x227bc153` | `MathOverflowedMulDiv()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0xa18ee550` | `Paymaster__InsufficientBalance()` |
| `0x77fc5689` | `Paymaster__InvalidGasCostCap()` |
| `0x89c61c06` | `Paymaster__InvalidOraclePrice()` |
| `0x4fd3f395` | `Paymaster__InvalidPaymasterData()` |
| `0x2cbc9627` | `Paymaster__InvalidServiceFee()` |
| `0x7db204b2` | `Paymaster__InvalidStalenessThreshold()` |
| `0x847be5d9` | `Paymaster__InvalidTokenBalance()` |
| `0x74f8ff90` | `Paymaster__MaxTokensReached()` |
| `0x7f3c57b5` | `Paymaster__OnlyEntryPoint()` |
| `0x4ddcc820` | `Paymaster__Paused()` |
| `0x7d1bece7` | `Paymaster__PriceNotInitialized()` |
| `0x192dbd6a` | `Paymaster__RegistryNotSet()` |
| `0x63862ed8` | `Paymaster__TokenDecimalsTooLarge()` |
| `0x51b3a251` | `Paymaster__TokenNotInList()` |
| `0x5f77d0bd` | `Paymaster__TokenNotSupported()` |
| `0x2462edf1` | `Paymaster__ZeroAddress()` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x5274afe7` | `SafeERC20FailedOperation(address)` |

## IERC20Metadata

- **Source:** `contracts/src/paymasters/v4/PaymasterBase.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x313ce567` | `decimals()` | view | — |  |

### Functions

#### `decimals()`

`0x313ce567` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

## PaymasterBase

- **Source:** `contracts/src/paymasters/v4/PaymasterBase.sol`
- **Functions:** 48 · **Events:** 14 · **Errors:** 23
- **Title:** PaymasterBase
- V4 Deposit-Only Paymaster with Community Pricing

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x4a58db19` | `addDeposit()` | payable | onlyOwner |  |
| `0x0396cb60` | `addStake(uint32)` | payable | onlyOwner |  |
| `0xc23f001f` | `balances(address,address)` | view | — | User Internal Balances: User -> Token -> Amount (Deposit-Only Model) |
| `0xce6771c9` | `CACHED_PRICE_DELTA_BPS()` | view | — |  |
| `0x84b863a8` | `CACHED_PRICE_MAX()` | view | — |  |
| `0xc7c6bd2c` | `CACHED_PRICE_MIN()` | view | — | P0-11: bounds for `setCachedPrice` (ETH/USD, 8 decimals).         $100 floor guards the crash-to-zero attack where an owner         could set price=1 making every UserOp appear free. $1M ceiling         rules out off-by-1e8 typos. ±30% per-tx delta reflects ETH         intraday extremes while blocking multi-step manipulation. |
| `0xf60fdcb3` | `cachedPrice()` | view | — | Cached ETH/USD price for validation |
| `0x5dbfc94d` | `calculateCost(uint256,address,bool)` | view | — | External wrapper that respects the Realtime Flag (New Optimization) |
| `0xb3db428b` | `depositFor(address,address,uint256)` | nonpayable | nonReentrant | Deposit funds for user (Push Model) |
| `0xb0d691fe` | `entryPoint()` | view | — | EntryPoint contract address |
| `0x42f6fb29` | `ethUsdPriceFeed()` | view | — | Chainlink ETH/USD price feedChainlink ETH/USD price feed |
| `0xd3c7c2c7` | `getSupportedTokens()` | view | — | Get all supported token addresses |
| `0xdb110a07` | `getSupportedTokensInfo()` | view | — | Get full info for all supported tokens |
| `0x75151b63` | `isTokenSupported(address)` | view | — | Check if a token is supported |
| `0x39788cd9` | `MAX_ETH_USD_PRICE()` | view | — | Maximum acceptable ETH/USD price from oracle ($100,000) |
| `0x3400ba52` | `MAX_GAS_TOKENS()` | view | — | Maximum number of supported GasTokens |
| `0xaa51e015` | `MAX_SBTS()` | view | — | Maximum number of supported SBTs |
| `0x14d90e1b` | `MAX_SERVICE_FEE()` | view | — | Maximum service fee (10%) |
| `0x0879c412` | `maxGasCostCap()` | view | — | Maximum gas cost cap per transaction (in wei) |
| `0x32726684` | `MIN_ETH_USD_PRICE()` | view | — | Minimum acceptable ETH/USD price from oracle ($100) |
| `0xe68b52e7` | `oracleDecimals()` | view | — | Cached oracle decimals to avoid external call in validate |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x8456cb59` | `pause()` | nonpayable | onlyOwner | Halt sponsorship locally — `whenNotPaused` modifier on         validatePaymasterUserOp will revert all new userOps. |
| `0x5c975abb` | `paused()` | view | — | Emergency pause flag |
| `0x7c627b21` | `postOp(uint8,bytes,uint256,uint256)` | nonpayable | onlyEntryPoint, nonReentrant | PostOp handler with refund logic |
| `0xbd111870` | `priceStalenessThreshold()` | view | — | Price staleness threshold (seconds) |
| `0x5fa7b584` | `removeToken(address)` | nonpayable | onlyOwner | Remove a supported token |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x61d1bc94` | `serviceFeeRate()` | view | — | Service fee rate in basis points (200 = 2%) |
| `0x083e91c4` | `setCachedPrice(uint256,uint48)` | nonpayable | onlyOwner | Direct Cache Update (Operator/Keeper Pushed Price) |
| `0xc9929dad` | `setMaxGasCostCap(uint256)` | nonpayable | onlyOwner |  |
| `0x4915a858` | `setPriceStalenessThreshold(uint256)` | nonpayable | onlyOwner |  |
| `0x9b1d3091` | `setServiceFeeRate(uint256)` | nonpayable | onlyOwner |  |
| `0x431f63c9` | `setTokenPrice(address,uint256)` | nonpayable | onlyOwner | Set supported token price (enable or update token) |
| `0xf0f44260` | `setTreasury(address)` | nonpayable | onlyOwner |  |
| `0x975dd5be` | `TIMESTAMP_GRACE_SECONDS()` | view | — | Grace window for keeper-pushed timestamps (seconds). |
| `0x8ee573ac` | `tokenDecimals(address)` | view | — |  |
| `0x204120bc` | `tokenPrices(address)` | view | — | Token Price in USD (8 decimals) set by Admin/Keeper |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x61d027b3` | `treasury()` | view | — | Treasury address - service provider's collection account |
| `0xbb9fe6bf` | `unlockStake()` | nonpayable | onlyOwner |  |
| `0x3f4ba83a` | `unpause()` | nonpayable | onlyOwner |  |
| `0x673a7e28` | `updatePrice()` | nonpayable | — | Update cached price from Oracle (Keeper only) |
| `0x52b7512c` | `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)` | nonpayable | onlyEntryPoint, whenNotPaused, nonReentrant | Validates paymaster operation and deducts internal balance |
| `0x54fd4d50` | `version()` | pure | — | Contract version |
| `0xf3fef3a3` | `withdraw(address,uint256)` | nonpayable | whenNotPaused, nonReentrant | Withdraw funds |
| `0xc23a5cea` | `withdrawStake(address)` | nonpayable | onlyOwner |  |
| `0x205c2878` | `withdrawTo(address,uint256)` | nonpayable | onlyOwner |  |

### Functions

#### `addDeposit()`

`0x4a58db19` · payable · access: onlyOwner

#### `addStake(uint32 unstakeDelaySec)`

`0x0396cb60` · payable · access: onlyOwner

| param | type | description |
|---|---|---|
| `unstakeDelaySec` | `uint32` |  |

#### `balances(address arg0, address arg1)`

`0xc23f001f` · view · access: —

> User Internal Balances: User -> Token -> Amount (Deposit-Only Model)

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_DELTA_BPS()`

`0xce6771c9` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_MAX()`

`0x84b863a8` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `CACHED_PRICE_MIN()`

`0xc7c6bd2c` · view · access: —

> P0-11: bounds for `setCachedPrice` (ETH/USD, 8 decimals).         $100 floor guards the crash-to-zero attack where an owner         could set price=1 making every UserOp appear free. $1M ceiling         rules out off-by-1e8 typos. ±30% per-tx delta reflects ETH         intraday extremes while blocking multi-step manipulation.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `cachedPrice()`

`0xf60fdcb3` · view · access: —

> Cached ETH/USD price for validation

| returns | type | description |
|---|---|---|
| `price` | `uint208` |  |
| `updatedAt` | `uint48` |  |

#### `calculateCost(uint256 gasCost, address token, bool useRealtime)`

`0x5dbfc94d` · view · access: —

> External wrapper that respects the Realtime Flag (New Optimization)

| param | type | description |
|---|---|---|
| `gasCost` | `uint256` |  |
| `token` | `address` |  |
| `useRealtime` | `bool` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `depositFor(address user, address token, uint256 amount)`

`0xb3db428b` · nonpayable · access: nonReentrant

> Deposit funds for user (Push Model)

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `token` | `address` |  |
| `amount` | `uint256` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> EntryPoint contract address

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `ethUsdPriceFeed()`

`0x42f6fb29` · view · access: —

> Chainlink ETH/USD price feedChainlink ETH/USD price feed

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getSupportedTokens()`

`0xd3c7c2c7` · view · access: —

> Get all supported token addresses

| returns | type | description |
|---|---|---|
| `_0` | `address[]` |  |

#### `getSupportedTokensInfo()`

`0xdb110a07` · view · access: —

> Get full info for all supported tokens

| returns | type | description |
|---|---|---|
| `tokens` | `address[]` | Array of token addresses |
| `prices` | `uint256[]` | Array of USD prices (8 decimals) |
| `decimalsArr` | `uint8[]` | Array of token decimals |

#### `isTokenSupported(address token)`

`0x75151b63` · view · access: —

> Check if a token is supported

| param | type | description |
|---|---|---|
| `token` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `MAX_ETH_USD_PRICE()`

`0x39788cd9` · view · access: —

> Maximum acceptable ETH/USD price from oracle ($100,000)

| returns | type | description |
|---|---|---|
| `_0` | `int256` |  |

#### `MAX_GAS_TOKENS()`

`0x3400ba52` · view · access: —

> Maximum number of supported GasTokens

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MAX_SBTS()`

`0xaa51e015` · view · access: —

> Maximum number of supported SBTs

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MAX_SERVICE_FEE()`

`0x14d90e1b` · view · access: —

> Maximum service fee (10%)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `maxGasCostCap()`

`0x0879c412` · view · access: —

> Maximum gas cost cap per transaction (in wei)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `MIN_ETH_USD_PRICE()`

`0x32726684` · view · access: —

> Minimum acceptable ETH/USD price from oracle ($100)

| returns | type | description |
|---|---|---|
| `_0` | `int256` |  |

#### `oracleDecimals()`

`0xe68b52e7` · view · access: —

> Cached oracle decimals to avoid external call in validate

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pause()`

`0x8456cb59` · nonpayable · access: onlyOwner

> Halt sponsorship locally — `whenNotPaused` modifier on         validatePaymasterUserOp will revert all new userOps.

*@dev* The original code shipped `paused`, `whenNotPaused`, and the         Paused/Unpaused events, but no setter — the modifier could         never become true, leaving operators with no on-chain stop.         Combined with P0-5 (Registry exitRole) this gives V4 paymasters         a fast local halt and a coordinated registry-level deactivation.

#### `paused()`

`0x5c975abb` · view · access: —

> Emergency pause flag

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 arg3)`

`0x7c627b21` · nonpayable · access: onlyEntryPoint, nonReentrant

> PostOp handler with refund logic

*@dev* Intentionally NOT guarded by whenNotPaused — UserOps that already      passed validatePaymasterUserOp must be allowed to settle; blocking      postOp would strand the EntryPoint and waste the bundler's gas.      Pause semantics: no new ops (validate blocked) + no withdrawals;      existing in-flight ops complete normally.

| param | type | description |
|---|---|---|
| `mode` | `uint8` |  |
| `context` | `bytes` |  |
| `actualGasCost` | `uint256` |  |
| `arg3` | `uint256` |  |

#### `priceStalenessThreshold()`

`0xbd111870` · view · access: —

> Price staleness threshold (seconds)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `removeToken(address token)`

`0x5fa7b584` · nonpayable · access: onlyOwner

> Remove a supported token

| param | type | description |
|---|---|---|
| `token` | `address` | ERC20 token address to remove |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `serviceFeeRate()`

`0x61d1bc94` · view · access: —

> Service fee rate in basis points (200 = 2%)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `setCachedPrice(uint256 price, uint48 timestamp)`

`0x083e91c4` · nonpayable · access: onlyOwner

> Direct Cache Update (Operator/Keeper Pushed Price)

*@dev* P0-16 (Codex B-N1): reject future timestamps. A future `updatedAt`      bypasses staleness checks and underflows the postOp staleness      subtraction in `_postOp`, bricking that path until the cache is      overwritten with a valid (past) timestamp.      A 15-second grace window (TIMESTAMP_GRACE_SECONDS) accommodates the      ~12 s maximum drift between a keeper's wall-clock and block.timestamp,      preventing spurious rejections of honest keepers.P0-11 (B2-N3 / V4): three guards stack on top of the P0-16      future-timestamp check:      - absolute MIN/MAX: prevent $0 / typo / crash-to-zero attacks      - ±30% per-tx delta (vs current cache): limits blast of a        misclick or partially-compromised owner key; skipped when        cachedPrice is uninitialised (first push).

| param | type | description |
|---|---|---|
| `price` | `uint256` | ETH/USD price (8 decimals) |
| `timestamp` | `uint48` | Timestamp of the price |

#### `setMaxGasCostCap(uint256 _maxGasCostCap)`

`0xc9929dad` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_maxGasCostCap` | `uint256` |  |

#### `setPriceStalenessThreshold(uint256 _priceStalenessThreshold)`

`0x4915a858` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_priceStalenessThreshold` | `uint256` |  |

#### `setServiceFeeRate(uint256 _serviceFeeRate)`

`0x9b1d3091` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_serviceFeeRate` | `uint256` |  |

#### `setTokenPrice(address token, uint256 price)`

`0x431f63c9` · nonpayable · access: onlyOwner

> Set supported token price (enable or update token)

| param | type | description |
|---|---|---|
| `token` | `address` | ERC20 token address |
| `price` | `uint256` | USD price with 8 decimals (e.g. 1e8 = $1.00) |

#### `setTreasury(address _treasury)`

`0xf0f44260` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_treasury` | `address` |  |

#### `TIMESTAMP_GRACE_SECONDS()`

`0x975dd5be` · view · access: —

> Grace window for keeper-pushed timestamps (seconds).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tokenDecimals(address arg0)`

`0x8ee573ac` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `tokenPrices(address arg0)`

`0x204120bc` · view · access: —

> Token Price in USD (8 decimals) set by Admin/Keeper

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `treasury()`

`0x61d027b3` · view · access: —

> Treasury address - service provider's collection account

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `unlockStake()`

`0xbb9fe6bf` · nonpayable · access: onlyOwner

#### `unpause()`

`0x3f4ba83a` · nonpayable · access: onlyOwner

#### `updatePrice()`

`0x673a7e28` · nonpayable · access: —

> Update cached price from Oracle (Keeper only)

#### `validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 arg1, uint256 maxCost)`

`0x52b7512c` · nonpayable · access: onlyEntryPoint, whenNotPaused, nonReentrant

> Validates paymaster operation and deducts internal balance

*@dev* Deposit-Only mode: Checks internal balance, NO external calls.

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` |  |
| `arg1` | `bytes32` |  |
| `maxCost` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `context` | `bytes` |  |
| `validationData` | `uint256` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Contract version

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `withdraw(address token, uint256 amount)`

`0xf3fef3a3` · nonpayable · access: whenNotPaused, nonReentrant

> Withdraw funds

*@dev* whenNotPaused: during a security incident we must prevent fund      drain while still allowing new deposits (depositFor is unguarded      because adding funds is never dangerous).

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `amount` | `uint256` |  |

#### `withdrawStake(address withdrawAddress)`

`0xc23a5cea` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `withdrawAddress` | `address` |  |

#### `withdrawTo(address withdrawAddress, uint256 amount)`

`0x205c2878` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `withdrawAddress` | `address` |  |
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0xf0d0e99cae184d0187b093b48894117462462379674a6e11d89c3fbb618e96b0` | `FundsDeposited(address,address,uint256)` |
| `0xa92ff919b850e4909ab2261d907ef955f11bc1716733a6cbece38d163a69af8a` | `FundsWithdrawn(address,address,uint256)` |
| `0x49081791577ea5202d6975e5d6ad3a55a49709b1adf70fbd4fbf4b3ffda6e031` | `MaxGasCostCapUpdated(uint256,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` | `Paused(address)` |
| `0x62544d7f48b11c32334310ebd306b47224fca220163218d4a7264322c52ae073` | `PostOpProcessed(address,address,uint256,uint256,uint256)` |
| `0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838` | `PriceUpdated(uint256,uint256)` |
| `0x2b5186a49160aeb8b14d6c82226402a1645e57be3d6219529ab397ee97413475` | `PriceUpdateFailed()` |
| `0x003b413cf14a67407425bd0b5c065b2de08876554d8489ad7dd4aa95604d280c` | `ServiceFeeUpdated(uint256,uint256)` |
| `0x2cfed7ac4be4a0009ef1af32ea2de149e0122938cb9aa4b3f7df3be6da1055e9` | `StalenessThresholdUpdated(uint256,uint256)` |
| `0xceb40be0a58aa33916c199e469842b614ef313295573c15d82f85cc9d1a89d32` | `TokenPriceUpdated(address,uint256)` |
| `0x4c910b69fe65a61f7531b9c5042b2329ca7179c77290aa7e2eb3afa3c8511fd3` | `TokenRemoved(address)` |
| `0x4ab5be82436d353e61ca18726e984e561f5c1cc7c6d38b29d2553c790434705a` | `TreasuryUpdated(address,address)` |
| `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` | `Unpaused(address)` |

### Errors

| selector | error |
|---|---|
| `0x9996b315` | `AddressEmptyCode(address)` |
| `0xcd786059` | `AddressInsufficientBalance(address)` |
| `0x1425ea42` | `FailedInnerCall()` |
| `0x227bc153` | `MathOverflowedMulDiv()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0xa18ee550` | `Paymaster__InsufficientBalance()` |
| `0x77fc5689` | `Paymaster__InvalidGasCostCap()` |
| `0x89c61c06` | `Paymaster__InvalidOraclePrice()` |
| `0x4fd3f395` | `Paymaster__InvalidPaymasterData()` |
| `0x2cbc9627` | `Paymaster__InvalidServiceFee()` |
| `0x7db204b2` | `Paymaster__InvalidStalenessThreshold()` |
| `0x847be5d9` | `Paymaster__InvalidTokenBalance()` |
| `0x74f8ff90` | `Paymaster__MaxTokensReached()` |
| `0x7f3c57b5` | `Paymaster__OnlyEntryPoint()` |
| `0x4ddcc820` | `Paymaster__Paused()` |
| `0x7d1bece7` | `Paymaster__PriceNotInitialized()` |
| `0x63862ed8` | `Paymaster__TokenDecimalsTooLarge()` |
| `0x51b3a251` | `Paymaster__TokenNotInList()` |
| `0x5f77d0bd` | `Paymaster__TokenNotSupported()` |
| `0x2462edf1` | `Paymaster__ZeroAddress()` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x5274afe7` | `SafeERC20FailedOperation(address)` |

## GToken

- **Source:** `contracts/src/tokens/GToken.sol`
- **Functions:** 18 · **Events:** 3 · **Errors:** 10
- **Title:** GToken v2.1.0 - Governance Token with Burnable Support
- ERC20 governance token with minting cap, burn capability, and version() interface

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xdd62ed3e` | `allowance(address,address)` | view | — |  |
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x42966c68` | `burn(uint256)` | nonpayable | — |  |
| `0x79cc6790` | `burnFrom(address,uint256)` | nonpayable | — |  |
| `0x355274ea` | `cap()` | view | — |  |
| `0x313ce567` | `decimals()` | view | — |  |
| `0x40c10f19` | `mint(address,uint256)` | nonpayable | onlyOwner | Mint new tokens (only owner) |
| `0x06fdde03` | `name()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x349f0b90` | `remainingMintableSupply()` | view | — | Get remaining mintable supply |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0x18160ddd` | `totalSupply()` | view | — |  |
| `0xa9059cbb` | `transfer(address,uint256)` | nonpayable | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `allowance(address owner, address spender)`

`0xdd62ed3e` · view · access: —

*@dev* See {IERC20-allowance}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `approve(address spender, uint256 value)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC20-approve}. NOTE: If `value` is the maximum `uint256`, the allowance is not updated on `transferFrom`. This is semantically equivalent to an infinite approval. Requirements: - `spender` cannot be the zero address.

| param | type | description |
|---|---|---|
| `spender` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `balanceOf(address account)`

`0x70a08231` · view · access: —

*@dev* See {IERC20-balanceOf}.

| param | type | description |
|---|---|---|
| `account` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `burn(uint256 value)`

`0x42966c68` · nonpayable · access: —

*@dev* Destroys a `value` amount of tokens from the caller. See {ERC20-_burn}.

| param | type | description |
|---|---|---|
| `value` | `uint256` |  |

#### `burnFrom(address account, uint256 value)`

`0x79cc6790` · nonpayable · access: —

*@dev* Destroys a `value` amount of tokens from `account`, deducting from the caller's allowance. See {ERC20-_burn} and {ERC20-allowance}. Requirements: - the caller must have allowance for ``accounts``'s tokens of at least `value`.

| param | type | description |
|---|---|---|
| `account` | `address` |  |
| `value` | `uint256` |  |

#### `cap()`

`0x355274ea` · view · access: —

*@dev* Returns the cap on the token's total supply.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `decimals()`

`0x313ce567` · view · access: —

*@dev* Returns the number of decimals used to get its user representation. For example, if `decimals` equals `2`, a balance of `505` tokens should be displayed to a user as `5.05` (`505 / 10 ** 2`). Tokens usually opt for a value of 18, imitating the relationship between Ether and Wei. This is the default value returned by this function, unless it's overridden. NOTE: This information is only used for _display_ purposes: it in no way affects any of the arithmetic of the contract, including {IERC20-balanceOf} and {IERC20-transfer}.

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `mint(address to, uint256 amount)`

`0x40c10f19` · nonpayable · access: onlyOwner

> Mint new tokens (only owner)

| param | type | description |
|---|---|---|
| `to` | `address` | Recipient address |
| `amount` | `uint256` | Amount to mint |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* Returns the name of the token.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `remainingMintableSupply()`

`0x349f0b90` · view · access: —

> Get remaining mintable supply

*@dev* This value increases when tokens are burned

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Amount of tokens that can still be minted before reaching cap |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* Returns the symbol of the token, usually a shorter version of the name.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `totalSupply()`

`0x18160ddd` · view · access: —

*@dev* See {IERC20-totalSupply}.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transfer(address to, uint256 value)`

`0xa9059cbb` · nonpayable · access: —

*@dev* See {IERC20-transfer}. Requirements: - `to` cannot be the zero address. - the caller must have a balance of at least `value`.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferFrom(address from, address to, uint256 value)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC20-transferFrom}. Emits an {Approval} event indicating the updated allowance. This is not required by the EIP. See the note at the beginning of {ERC20}. NOTE: Does not update the allowance if the current allowance is the maximum `uint256`. Requirements: - `from` and `to` cannot be the zero address. - `from` must have a balance of at least `value`. - the caller must have allowance for ``from``'s tokens of at least `value`.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x9e79f854` | `ERC20ExceededCap(uint256,uint256)` |
| `0xfb8f41b2` | `ERC20InsufficientAllowance(address,uint256,uint256)` |
| `0xe450d38c` | `ERC20InsufficientBalance(address,uint256,uint256)` |
| `0xe602df05` | `ERC20InvalidApprover(address)` |
| `0x392e1e27` | `ERC20InvalidCap(uint256)` |
| `0xec442f05` | `ERC20InvalidReceiver(address)` |
| `0x96c6fd1e` | `ERC20InvalidSender(address)` |
| `0x94280d62` | `ERC20InvalidSpender(address)` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## GTokenAuthorization

- **Source:** `contracts/src/tokens/GTokenAuthorization.sol`
- **Functions:** 31 · **Events:** 6 · **Errors:** 21
- **Title:** GTokenAuthorization v2.2.0 — GToken with EIP-3009 gasless transfers
- Extends GToken with two EIP-3009 transfer paths and two risk controls. Transfer paths ────────────── transferWithAuthorization  — any relay can call; suitable for simple gasless sends. receiveWithAuthorization   — only msg.sender == to may call; prevents front-running                              for atomic deposit/wrapper flows (e.g. UI-driven UIDC                              purchases where the contract must be the caller). Risk controls ───────────── RC-1  Validity window hard-capped at MAX_AUTH_VALIDITY (5 min).       Limits the attack surface if a signature is intercepted. RC-2  Recipient must hold mySBT OR any xPNTs token issued by `factory`.       Covers the entire protocol ecosystem — all past and future communities —       without redeployment. `xPNTsToken` is a relay-supplied calldata hint       (not EIP-712 signed) because it only gates access; funds always flow to       the signature-bound `to` address.       Note: balanceOf is an at-execution snapshot; a recipient that briefly       holds xPNTs will pass RC-2. Persistent membership enforcement requires       a registry/lock mechanism (out of scope for this contract).       If mySBT has not been set yet, RC-2 falls back to xPNTs path only. Execution order (gas-optimal) ───────────────────────────── 1. Time-window checks  (pure arithmetic, cheapest) 2. Nonce state check   (1 SLOAD) 3. Signature recovery  (ecrecover, ~3k gas) 4. RC-2 eligibility    (≤3 external calls, most expensive — runs only on valid sigs) Deployment dependency ───────────────────── Deploy order: Registry → xPNTsFactory → GTokenAuthorization → GTokenStaking → MySBT               → GTokenAuthorization.setMySBT(mysbt) mySBT is set post-deploy (one-time, owner-only) to avoid circular constructor deps. factory is immutable — wrong address at deploy is permanent.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xdd62ed3e` | `allowance(address,address)` | view | — |  |
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0xe94a0102` | `authorizationState(address,bytes32)` | view | — | Read nonce state for a given authorizer. |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x42966c68` | `burn(uint256)` | nonpayable | — |  |
| `0x79cc6790` | `burnFrom(address,uint256)` | nonpayable | — |  |
| `0xd9169487` | `CANCEL_AUTHORIZATION_TYPEHASH()` | view | — |  |
| `0xb7b72899` | `cancelAuthorization(address,bytes32,bytes)` | nonpayable | — | Permanently cancel an unused nonce so it can never be executed.         Must be signed by `authorizer`. |
| `0x355274ea` | `cap()` | view | — |  |
| `0x313ce567` | `decimals()` | view | — |  |
| `0x3644e515` | `DOMAIN_SEPARATOR()` | view | — |  |
| `0x84b0196e` | `eip712Domain()` | view | — |  |
| `0xc45a0155` | `factory()` | view | — |  |
| `0xcc1fb85d` | `MAX_AUTH_VALIDITY()` | view | — |  |
| `0x40c10f19` | `mint(address,uint256)` | nonpayable | — | Mint new tokens (only owner) |
| `0xabcd5a04` | `mySBT()` | view | — |  |
| `0x06fdde03` | `name()` | view | — |  |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0x7f2eecc3` | `RECEIVE_WITH_AUTHORIZATION_TYPEHASH()` | view | — |  |
| `0x0b3167cd` | `receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,address,bytes)` | nonpayable | — | Gasless transfer where only the recipient may submit the authorization.         Prevents front-running for atomic contract flows (deposit, wrap, etc.).         msg.sender must equal `to`. |
| `0x349f0b90` | `remainingMintableSupply()` | view | — | Get remaining mintable supply |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xcd5d1e74` | `setMySBT(address)` | nonpayable | onlyOwner | Set the mySBT contract address (one-time, owner only).         Call this after MySBT is deployed. Until set, RC-2 falls back to xPNTs path. |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0x18160ddd` | `totalSupply()` | view | — |  |
| `0xa0cc6a68` | `TRANSFER_WITH_AUTHORIZATION_TYPEHASH()` | view | — |  |
| `0xa9059cbb` | `transfer(address,uint256)` | nonpayable | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x96cdf47a` | `transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,address,bytes)` | nonpayable | — | Gasless transfer: any relay may call on behalf of `from`. |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `allowance(address owner, address spender)`

`0xdd62ed3e` · view · access: —

*@dev* See {IERC20-allowance}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `approve(address spender, uint256 value)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC20-approve}. NOTE: If `value` is the maximum `uint256`, the allowance is not updated on `transferFrom`. This is semantically equivalent to an infinite approval. Requirements: - `spender` cannot be the zero address.

| param | type | description |
|---|---|---|
| `spender` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `authorizationState(address authorizer, bytes32 nonce)`

`0xe94a0102` · view · access: —

> Read nonce state for a given authorizer.

| param | type | description |
|---|---|---|
| `authorizer` | `address` |  |
| `nonce` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `balanceOf(address account)`

`0x70a08231` · view · access: —

*@dev* See {IERC20-balanceOf}.

| param | type | description |
|---|---|---|
| `account` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `burn(uint256 value)`

`0x42966c68` · nonpayable · access: —

*@dev* Destroys a `value` amount of tokens from the caller. See {ERC20-_burn}.

| param | type | description |
|---|---|---|
| `value` | `uint256` |  |

#### `burnFrom(address account, uint256 value)`

`0x79cc6790` · nonpayable · access: —

*@dev* Destroys a `value` amount of tokens from `account`, deducting from the caller's allowance. See {ERC20-_burn} and {ERC20-allowance}. Requirements: - the caller must have allowance for ``accounts``'s tokens of at least `value`.

| param | type | description |
|---|---|---|
| `account` | `address` |  |
| `value` | `uint256` |  |

#### `CANCEL_AUTHORIZATION_TYPEHASH()`

`0xd9169487` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `cancelAuthorization(address authorizer, bytes32 nonce, bytes signature)`

`0xb7b72899` · nonpayable · access: —

> Permanently cancel an unused nonce so it can never be executed.         Must be signed by `authorizer`.

*@dev* An empty or malformed `signature` causes ECDSA.tryRecover to return      RecoverError.InvalidSignatureLength / InvalidSignature, which reverts      with InvalidSignature(). SDK callers should ensure the signature is a      valid 65-byte ECDSA signature over the CancelAuthorization digest.

| param | type | description |
|---|---|---|
| `authorizer` | `address` |  |
| `nonce` | `bytes32` |  |
| `signature` | `bytes` |  |

#### `cap()`

`0x355274ea` · view · access: —

*@dev* Returns the cap on the token's total supply.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `decimals()`

`0x313ce567` · view · access: —

*@dev* Returns the number of decimals used to get its user representation. For example, if `decimals` equals `2`, a balance of `505` tokens should be displayed to a user as `5.05` (`505 / 10 ** 2`). Tokens usually opt for a value of 18, imitating the relationship between Ether and Wei. This is the default value returned by this function, unless it's overridden. NOTE: This information is only used for _display_ purposes: it in no way affects any of the arithmetic of the contract, including {IERC20-balanceOf} and {IERC20-transfer}.

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `DOMAIN_SEPARATOR()`

`0x3644e515` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `eip712Domain()`

`0x84b0196e` · view · access: —

*@dev* See {IERC-5267}.

| returns | type | description |
|---|---|---|
| `fields` | `bytes1` |  |
| `name` | `string` |  |
| `version` | `string` |  |
| `chainId` | `uint256` |  |
| `verifyingContract` | `address` |  |
| `salt` | `bytes32` |  |
| `extensions` | `uint256[]` |  |

#### `factory()`

`0xc45a0155` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `MAX_AUTH_VALIDITY()`

`0xcc1fb85d` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `mint(address to, uint256 amount)`

`0x40c10f19` · nonpayable · access: —

> Mint new tokens (only owner)

| param | type | description |
|---|---|---|
| `to` | `address` | Recipient address |
| `amount` | `uint256` | Amount to mint |

#### `mySBT()`

`0xabcd5a04` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* Returns the name of the token.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `RECEIVE_WITH_AUTHORIZATION_TYPEHASH()`

`0x7f2eecc3` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, address xPNTsToken, bytes signature)`

`0x0b3167cd` · nonpayable · access: —

> Gasless transfer where only the recipient may submit the authorization.         Prevents front-running for atomic contract flows (deposit, wrap, etc.).         msg.sender must equal `to`.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `xPNTsToken` | `address` |  |
| `signature` | `bytes` |  |

#### `remainingMintableSupply()`

`0x349f0b90` · view · access: —

> Get remaining mintable supply

*@dev* This value increases when tokens are burned

| returns | type | description |
|---|---|---|
| `_0` | `uint256` | Amount of tokens that can still be minted before reaching cap |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `setMySBT(address mySBT_)`

`0xcd5d1e74` · nonpayable · access: onlyOwner

> Set the mySBT contract address (one-time, owner only).         Call this after MySBT is deployed. Until set, RC-2 falls back to xPNTs path.

| param | type | description |
|---|---|---|
| `mySBT_` | `address` |  |

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* Returns the symbol of the token, usually a shorter version of the name.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `totalSupply()`

`0x18160ddd` · view · access: —

*@dev* See {IERC20-totalSupply}.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `TRANSFER_WITH_AUTHORIZATION_TYPEHASH()`

`0xa0cc6a68` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `transfer(address to, uint256 value)`

`0xa9059cbb` · nonpayable · access: —

*@dev* See {IERC20-transfer}. Requirements: - `to` cannot be the zero address. - the caller must have a balance of at least `value`.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferFrom(address from, address to, uint256 value)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC20-transferFrom}. Emits an {Approval} event indicating the updated allowance. This is not required by the EIP. See the note at the beginning of {ERC20}. NOTE: Does not update the allowance if the current allowance is the maximum `uint256`. Requirements: - `from` and `to` cannot be the zero address. - `from` must have a balance of at least `value`. - the caller must have allowance for ``from``'s tokens of at least `value`.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, address xPNTsToken, bytes signature)`

`0x96cdf47a` · nonpayable · access: —

> Gasless transfer: any relay may call on behalf of `from`.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |
| `validAfter` | `uint256` |  |
| `validBefore` | `uint256` |  |
| `nonce` | `bytes32` |  |
| `xPNTsToken` | `address` | Factory-issued xPNTs token the relay asserts `to` holds.                    Pass address(0) to rely on SBT path alone.                    Not included in the EIP-712 signature (gate-check only). |
| `signature` | `bytes` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x1cdd46ff242716cdaa72d159d339a485b3438398348d68f09d7c8c0a59353d81` | `AuthorizationCanceled(address,bytes32)` |
| `0x98de503528ee59b575ef0c0a2576a82497bfc029a5685b209e9ec333479b10a5` | `AuthorizationUsed(address,bytes32)` |
| `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` | `EIP712DomainChanged()` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x0f05f5bf` | `AuthorizationExpired()` |
| `0xdf8e4372` | `AuthorizationNotYetValid()` |
| `0xcbea1001` | `AuthorizationUsedOrCanceled()` |
| `0xf833024c` | `AuthorizationWindowInvalid()` |
| `0xac582f56` | `AuthorizationWindowTooLong()` |
| `0xa56c0285` | `CallerMustBeRecipient()` |
| `0x9e79f854` | `ERC20ExceededCap(uint256,uint256)` |
| `0xfb8f41b2` | `ERC20InsufficientAllowance(address,uint256,uint256)` |
| `0xe450d38c` | `ERC20InsufficientBalance(address,uint256,uint256)` |
| `0xe602df05` | `ERC20InvalidApprover(address)` |
| `0x392e1e27` | `ERC20InvalidCap(uint256)` |
| `0xec442f05` | `ERC20InvalidReceiver(address)` |
| `0x96c6fd1e` | `ERC20InvalidSender(address)` |
| `0x94280d62` | `ERC20InvalidSpender(address)` |
| `0xb3512b0c` | `InvalidShortString()` |
| `0x8baa579f` | `InvalidSignature()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |
| `0x474081ed` | `RecipientNotInProtocol()` |
| `0x9902233e` | `SBTAlreadySet()` |
| `0x305a27a9` | `StringTooLong(string)` |

## MySBT

- **Source:** `contracts/src/tokens/MySBT.sol`
- **Functions:** 48 · **Events:** 17 · **Errors:** 25

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xc580163e` | `airdropMint(address,bytes32,bytes)` | nonpayable | onlyRegistry, whenNotPaused, nonReentrant | V3: Admin airdrop (DAO-paid minting) |
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x374e7fa3` | `burnSBT(address)` | nonpayable | onlyRegistry, whenNotPaused, nonReentrant |  |
| `0xc0d0aa69` | `daoMultisig()` | view | — |  |
| `0x5afc4b5c` | `deactivateAllMemberships(address)` | nonpayable | onlyRegistry | Deactivate all community memberships for a user |
| `0xd977b66b` | `deactivateMembership(address,address)` | nonpayable | onlyRegistry |  |
| `0x8ceebd8f` | `getActiveMemberships(uint256)` | view | — | Get all active memberships for an SBT |
| `0x081812fc` | `getApproved(uint256)` | view | — |  |
| `0x71eb90a1` | `getCommunityMembership(uint256,address)` | view | — |  |
| `0x556697da` | `getMemberships(uint256)` | view | — |  |
| `0xbf1fb0f2` | `getSBTData(uint256)` | view | — |  |
| `0x80f4b8c8` | `getUserSBT(address)` | view | — |  |
| `0x826600ce` | `GTOKEN_STAKING()` | view | — |  |
| `0x7f6b337b` | `GTOKEN()` | view | — |  |
| `0xe985e9c5` | `isApprovedForAll(address,address)` | view | — |  |
| `0x908c1018` | `lastActivityTime(uint256,address)` | view | — |  |
| `0xbead0513` | `leaveCommunity(address)` | nonpayable | whenNotPaused, nonReentrant |  |
| `0xa9eb37ba` | `MAX_MEMBERSHIPS()` | view | — | Maximum number of community memberships per SBT (gas cap for burnSBT loop). |
| `0xa1141b07` | `membershipIndex(uint256,address)` | view | — |  |
| `0x08804275` | `minLockAmount()` | view | — |  |
| `0x13966db5` | `mintFee()` | view | — |  |
| `0x3e3e6842` | `mintForRole(address,bytes32,bytes)` | nonpayable | onlyRegistry, whenNotPaused, nonReentrant | V3: Mint SBT for role registration (self-service registration) |
| `0x06fdde03` | `name()` | view | — |  |
| `0x75794a3c` | `nextTokenId()` | view | — |  |
| `0x6352211e` | `ownerOf(uint256)` | view | — |  |
| `0x8456cb59` | `pause()` | nonpayable | onlyDAO |  |
| `0x5c975abb` | `paused()` | view | — |  |
| `0x2f7c88f5` | `recordActivity(address)` | nonpayable | whenNotPaused | Record on-chain activity for a user in the caller's community. |
| `0x06433b1b` | `REGISTRY()` | view | — |  |
| `0xccbc10d0` | `reputationCalculator()` | view | — |  |
| `0xb88d4fde` | `safeTransferFrom(address,address,uint256,bytes)` | nonpayable | — |  |
| `0x42842e0e` | `safeTransferFrom(address,address,uint256)` | nonpayable | — |  |
| `0x776fafac` | `sbtData(uint256)` | view | — |  |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | nonpayable | — |  |
| `0x55f804b3` | `setBaseURI(string)` | nonpayable | onlyDAO |  |
| `0x4f8cc065` | `setDAOMultisig(address)` | nonpayable | onlyDAO |  |
| `0x0f68ae40` | `setMinLockAmount(uint256)` | nonpayable | onlyDAO |  |
| `0xeddd0d9c` | `setMintFee(uint256)` | nonpayable | onlyDAO |  |
| `0xa6109650` | `setReputationCalculator(address)` | nonpayable | onlyDAO |  |
| `0x01ffc9a7` | `supportsInterface(bytes4)` | view | — |  |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0xc87b56dd` | `tokenURI(uint256)` | view | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0x3f4ba83a` | `unpause()` | nonpayable | onlyDAO |  |
| `0x2d5a7f4f` | `userToSBT(address)` | view | — |  |
| `0x5bb5bf0c` | `verifyCommunityMembership(address,address)` | view | — |  |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `airdropMint(address u, bytes32 roleId, bytes roleData)`

`0xc580163e` · nonpayable · access: onlyRegistry, whenNotPaused, nonReentrant

> V3: Admin airdrop (DAO-paid minting)

*@dev* REMOVED staking logic - Registry handles all financial operations      MySBT only mints the SBT token itself      Called by Registry.safeMintForRole() for admin airdrops

| param | type | description |
|---|---|---|
| `u` | `address` | User address to receive SBT |
| `roleId` | `bytes32` | Role identifier |
| `roleData` | `bytes` | Role-specific metadata |

| returns | type | description |
|---|---|---|
| `tid` | `uint256` | Token ID (new or existing) |
| `isNew` | `bool` | True if new SBT was minted |

#### `approve(address to, uint256 tokenId)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC721-approve}.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

*@dev* See {IERC721-balanceOf}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `burnSBT(address u)`

`0x374e7fa3` · nonpayable · access: onlyRegistry, whenNotPaused, nonReentrant

| param | type | description |
|---|---|---|
| `u` | `address` |  |

#### `daoMultisig()`

`0xc0d0aa69` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `deactivateAllMemberships(address user)`

`0x5afc4b5c` · nonpayable · access: onlyRegistry

> Deactivate all community memberships for a user

*@dev* H-02 FIX: Called by Registry when user exits ENDUSER roleEnsures complete cleanup of all community memberships

| param | type | description |
|---|---|---|
| `user` | `address` | User address |

#### `deactivateMembership(address user, address community)`

`0xd977b66b` · nonpayable · access: onlyRegistry

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `community` | `address` |  |

#### `getActiveMemberships(uint256 tid)`

`0x8ceebd8f` · view · access: —

> Get all active memberships for an SBT

| param | type | description |
|---|---|---|
| `tid` | `uint256` | Token ID |

| returns | type | description |
|---|---|---|
| `active` | `address[]` | Array of active community addresses |

#### `getApproved(uint256 tokenId)`

`0x081812fc` · view · access: —

*@dev* See {IERC721-getApproved}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getCommunityMembership(uint256 tid, address comm)`

`0x71eb90a1` · view · access: —

| param | type | description |
|---|---|---|
| `tid` | `uint256` |  |
| `comm` | `address` |  |

| returns | type | description |
|---|---|---|
| `mem` | `(address,uint256,bool,string)` |  |

#### `getMemberships(uint256 tid)`

`0x556697da` · view · access: —

| param | type | description |
|---|---|---|
| `tid` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `(address,uint256,bool,string)[]` |  |

#### `getSBTData(uint256 tid)`

`0xbf1fb0f2` · view · access: —

| param | type | description |
|---|---|---|
| `tid` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `(address,address,uint256,uint256)` |  |

#### `getUserSBT(address u)`

`0x80f4b8c8` · view · access: —

| param | type | description |
|---|---|---|
| `u` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `GTOKEN_STAKING()`

`0x826600ce` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `GTOKEN()`

`0x7f6b337b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `isApprovedForAll(address owner, address operator)`

`0xe985e9c5` · view · access: —

*@dev* See {IERC721-isApprovedForAll}.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `lastActivityTime(uint256 arg0, address arg1)`

`0x908c1018` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `leaveCommunity(address comm)`

`0xbead0513` · nonpayable · access: whenNotPaused, nonReentrant

| param | type | description |
|---|---|---|
| `comm` | `address` |  |

#### `MAX_MEMBERSHIPS()`

`0xa9eb37ba` · view · access: —

> Maximum number of community memberships per SBT (gas cap for burnSBT loop).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `membershipIndex(uint256 arg0, address arg1)`

`0xa1141b07` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |
| `arg1` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `minLockAmount()`

`0x08804275` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `mintFee()`

`0x13966db5` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `mintForRole(address user, bytes32 roleId, bytes roleData)`

`0x3e3e6842` · nonpayable · access: onlyRegistry, whenNotPaused, nonReentrant

> V3: Mint SBT for role registration (self-service registration)

*@dev* Called by Registry when user registers a role via registerRole()      - Creates new SBT if user doesn't have one      - Records role metadata on existing SBT      - No staking/burning here (Registry handles that)

| param | type | description |
|---|---|---|
| `user` | `address` | User address to receive SBT |
| `roleId` | `bytes32` | Role identifier (e.g., ROLE_COMMUNITY, ROLE_ENDUSER) |
| `roleData` | `bytes` | Role-specific metadata (community address, etc.) |

| returns | type | description |
|---|---|---|
| `tokenId` | `uint256` | Token ID (new or existing) |
| `isNewMint` | `bool` | True if new SBT was minted |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* See {IERC721Metadata-name}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `nextTokenId()`

`0x75794a3c` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `ownerOf(uint256 tokenId)`

`0x6352211e` · view · access: —

*@dev* See {IERC721-ownerOf}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pause()`

`0x8456cb59` · nonpayable · access: onlyDAO

#### `paused()`

`0x5c975abb` · view · access: —

*@dev* Returns true if the contract is paused, and false otherwise.

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `recordActivity(address u)`

`0x2f7c88f5` · nonpayable · access: whenNotPaused

> Record on-chain activity for a user in the caller's community.

*@dev* Caller must be a community registered via Registry (_isValid check).      Communities call this directly — Registry is NOT the caller.      Rate-limited to once per MIN_INT seconds per (user, community) pair.

| param | type | description |
|---|---|---|
| `u` | `address` | User whose SBT activity timestamp is updated. |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `reputationCalculator()`

`0xccbc10d0` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId, bytes data)`

`0xb88d4fde` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |
| `data` | `bytes` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId)`

`0x42842e0e` · nonpayable · access: —

*@dev* See {IERC721-safeTransferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `sbtData(uint256 arg0)`

`0x776fafac` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `holder` | `address` |  |
| `firstCommunity` | `address` |  |
| `mintedAt` | `uint256` |  |
| `totalCommunities` | `uint256` |  |

#### `setApprovalForAll(address operator, bool approved)`

`0xa22cb465` · nonpayable · access: —

*@dev* See {IERC721-setApprovalForAll}.

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `approved` | `bool` |  |

#### `setBaseURI(string baseURI)`

`0x55f804b3` · nonpayable · access: onlyDAO

| param | type | description |
|---|---|---|
| `baseURI` | `string` |  |

#### `setDAOMultisig(address d)`

`0x4f8cc065` · nonpayable · access: onlyDAO

| param | type | description |
|---|---|---|
| `d` | `address` |  |

#### `setMinLockAmount(uint256 a)`

`0x0f68ae40` · nonpayable · access: onlyDAO

| param | type | description |
|---|---|---|
| `a` | `uint256` |  |

#### `setMintFee(uint256 f)`

`0xeddd0d9c` · nonpayable · access: onlyDAO

| param | type | description |
|---|---|---|
| `f` | `uint256` |  |

#### `setReputationCalculator(address c)`

`0xa6109650` · nonpayable · access: onlyDAO

| param | type | description |
|---|---|---|
| `c` | `address` |  |

#### `supportsInterface(bytes4 interfaceId)`

`0x01ffc9a7` · view · access: —

*@dev* See {IERC165-supportsInterface}.

| param | type | description |
|---|---|---|
| `interfaceId` | `bytes4` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* See {IERC721Metadata-symbol}.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `tokenURI(uint256 tokenId)`

`0xc87b56dd` · view · access: —

*@dev* See {IERC721Metadata-tokenURI}.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `transferFrom(address from, address to, uint256 tokenId)`

`0x23b872dd` · nonpayable · access: —

*@dev* See {IERC721-transferFrom}.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `unpause()`

`0x3f4ba83a` · nonpayable · access: onlyDAO

#### `userToSBT(address arg0)`

`0x2d5a7f4f` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `verifyCommunityMembership(address u, address comm)`

`0x5bb5bf0c` · view · access: —

| param | type | description |
|---|---|---|
| `u` | `address` |  |
| `comm` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x0bd2c5444bc0126737809a3970e1c3bc8cf29e5efb7d5448cbaa6a9c1af81207` | `ActivityRecorded(uint256,address,uint256,uint256)` |
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | `ApprovalForAll(address,address,bool)` |
| `0xce8257866c47f4cae1c27b1b0190cb5d26540e5a908cbf35974d6f300c63e11c` | `BaseURIUpdated(string,uint256)` |
| `0x80170b5fcdd2bf1e0660ef4b8851f86685f64d41b1a19de1471947ece8725aac` | `ContractPaused(address,uint256)` |
| `0x107553d8191d85b405879cf752997865edd48d94e20bda4dd27223c94b31a7cc` | `ContractUnpaused(address,uint256)` |
| `0x90de8705b1aaf3966be0e8ec8acf9aed10a6d3d0d572ec8f96112409e2820c61` | `DAOMultisigUpdated(address,address,uint256)` |
| `0xdce074e613075d639af3f726477d52ac48d3fbdb03f4aa8a9b1e6cede312db10` | `MembershipAdded(uint256,address,string,uint256)` |
| `0xee0396c067d25a2fde86b8e1c13e3995b0940b5f98651052d79fada14ea7dba5` | `MembershipDeactivated(uint256,address,uint256)` |
| `0x5d1f56e31e5dc1f29354822b887b1463ececf7edfad7c39216980b7dfd7ea97d` | `MinLockAmountUpdated(uint256,uint256,uint256)` |
| `0xd3950a5507479ea19c5c7766f5191546ace60f0a00dc360d52ce083b58f22331` | `MintFeeUpdated(uint256,uint256,uint256)` |
| `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` | `Paused(address)` |
| `0xb71a92720c720f655d24a8ebbeeb4c9875d85189ca58d32cb0e6997aa5e6c291` | `ReputationCalculatorUpdated(address,address,uint256)` |
| `0x108d98610c6944880c68d31a01ab6252b635e7c7a9728687f31e68a76538c865` | `SBTBurned(address,uint256,uint256,uint256,uint256)` |
| `0xf5491bdb765a4be5a1bdc9bfd09cf61e1b89962ac33ed2e928f11a59a5e72331` | `SBTMinted(address,uint256,address,uint256)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |
| `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` | `Unpaused(address)` |

### Errors

| selector | error |
|---|---|
| `0x0b161e70` | `ActivityTooSoon()` |
| `0x7554bad3` | `CommunityMismatch()` |
| `0xd93c0665` | `EnforcedPause()` |
| `0x64283d7b` | `ERC721IncorrectOwner(address,uint256,address)` |
| `0x177e802f` | `ERC721InsufficientApproval(address,uint256)` |
| `0xa9fbf51f` | `ERC721InvalidApprover(address)` |
| `0x5b08ba18` | `ERC721InvalidOperator(address)` |
| `0x89c62b64` | `ERC721InvalidOwner(address)` |
| `0x64a0ae92` | `ERC721InvalidReceiver(address)` |
| `0x73c6ac6e` | `ERC721InvalidSender(address)` |
| `0x7e273289` | `ERC721NonexistentToken(uint256)` |
| `0x8dfc202b` | `ExpectedPause()` |
| `0xe44ae7c9` | `InactiveMembership()` |
| `0xe6c4247b` | `InvalidAddress()` |
| `0x2c5211c6` | `InvalidAmount()` |
| `0x0f950187` | `InvalidCommunity()` |
| `0x63df8171` | `InvalidIndex()` |
| `0xfd684c3b` | `InvalidUser()` |
| `0x9cbe2357` | `NonTransferable()` |
| `0x999802f0` | `OnlyDAO()` |
| `0x87aa01c8` | `OnlyRegistry()` |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` |
| `0x59f1a2a1` | `RoleNotHeld()` |
| `0x4fc726b0` | `SBTNotFound()` |
| `0xd19f5674` | `TooManyMemberships()` |

## xPNTsFactory

- **Source:** `contracts/src/tokens/xPNTsFactory.sol`
- **Functions:** 34 · **Events:** 8 · **Errors:** 9
- **Title:** xPNTsFactory
- Factory for deploying xPNTs tokens with AI-powered deposit predictions

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x001b4db8` | `APNTS_PRICE_DELTA_BPS()` | view | — |  |
| `0xa121377a` | `APNTS_PRICE_MAX()` | view | — |  |
| `0x931c7065` | `APNTS_PRICE_MIN()` | view | — |  |
| `0x594a6f23` | `aPNTsPriceUSD()` | view | — | aPNTs USD price (18 decimals, e.g., 0.02e18 = $0.02) |
| `0x08c2ddcd` | `communityToToken(address)` | view | — | Mapping: community address => xPNTs token address |
| `0xa137891e` | `DEFAULT_SAFETY_FACTOR()` | view | — | Default safety factor: 1.5x (50% buffer) |
| `0xec81aadb` | `deployedTokens(uint256)` | view | — | List of all deployed tokens |
| `0x954ebd3b` | `deployxPNTsToken(string,string,string,string,uint256,address)` | nonpayable | — | Deploy new xPNTs token |
| `0x2a5c792a` | `getAllTokens()` | view | — | Get all deployed tokens |
| `0x59734e1a` | `getAPNTsPrice()` | view | — | Get current aPNTs USD price |
| `0x0ff65414` | `getDeployedCount()` | view | — | Get total deployed tokens count |
| `0xbe382cdb` | `getDepositBreakdown(address)` | view | — | Calculate deposit breakdown |
| `0xdf9a70ea` | `getIndustryMultiplier(string)` | view | — | Get industry multiplier |
| `0xae9a6d6f` | `getPredictionParams(address)` | view | — | Get prediction parameters for community |
| `0xb8d7b669` | `getTokenAddress(address)` | view | — | Get xPNTs token address for community |
| `0x9bb0f599` | `hasToken(address)` | view | — | Check if community has deployed token |
| `0x5c60da1b` | `implementation()` | view | — | The address of the xPNTsToken implementation contract used for cloning. |
| `0xab798449` | `industryMultipliers(string)` | view | — | Industry multipliers (name => value in 1e18) |
| `0x96e28d28` | `isXPNTs(address)` | view | — | Whitelist of tokens this factory has deployed. |
| `0x8dbb03b1` | `MIN_SUGGESTED_AMOUNT()` | view | — | Minimum suggested amount: 100 aPNTs |
| `0x8da5cb5b` | `owner()` | view | — |  |
| `0xb2bcfd34` | `predictDepositAmount(address)` | view | — | AI-powered deposit amount prediction |
| `0x35fa61fa` | `predictions(address)` | view | — | Mapping: community address => prediction parameters |
| `0x67d7bc06` | `propagateSuperPaymaster(uint256,uint256)` | nonpayable | onlyOwner | Propagate current SUPERPAYMASTER address to a batch of deployed tokens. |
| `0x06433b1b` | `REGISTRY()` | view | — | Registry contract address |
| `0x715018a6` | `renounceOwnership()` | nonpayable | — |  |
| `0xa5509758` | `setIndustryMultiplier(string,uint256)` | nonpayable | onlyOwner | Set industry multiplier (only owner) |
| `0x7ade132c` | `setSuperPaymasterAddress(address)` | nonpayable | onlyOwner |  |
| `0x5ae48ba4` | `SUPERPAYMASTER()` | view | — | SuperPaymaster contract address |
| `0xf2fde38b` | `transferOwnership(address)` | nonpayable | — |  |
| `0x2598c32a` | `updateAPNTsPrice(uint256)` | nonpayable | onlyOwner |  |
| `0x358064a8` | `updatePrediction(uint256,uint256,string,uint256)` | nonpayable | — | Update prediction parameters |
| `0x382c8036` | `updatePredictionCustom(uint256,uint256,uint256,uint256)` | nonpayable | — | Update prediction with custom multiplier |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `APNTS_PRICE_DELTA_BPS()`

`0x001b4db8` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `APNTS_PRICE_MAX()`

`0xa121377a` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `APNTS_PRICE_MIN()`

`0x931c7065` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `aPNTsPriceUSD()`

`0x594a6f23` · view · access: —

> aPNTs USD price (18 decimals, e.g., 0.02e18 = $0.02)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `communityToToken(address arg0)`

`0x08c2ddcd` · view · access: —

> Mapping: community address => xPNTs token address

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `DEFAULT_SAFETY_FACTOR()`

`0xa137891e` · view · access: —

> Default safety factor: 1.5x (50% buffer)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `deployedTokens(uint256 arg0)`

`0xec81aadb` · view · access: —

> List of all deployed tokens

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `deployxPNTsToken(string name, string symbol, string communityName, string communityENS, uint256 exchangeRate, address paymasterAOA)`

`0x954ebd3b` · nonpayable · access: —

> Deploy new xPNTs token

| param | type | description |
|---|---|---|
| `name` | `string` | Token name (e.g., "MyDAO Points") |
| `symbol` | `string` | Token symbol (e.g., "xMDAO") |
| `communityName` | `string` | Community display name |
| `communityENS` | `string` | Community ENS domain |
| `exchangeRate` | `uint256` | Exchange rate with aPNTs (18 decimals, e.g., 1e18 = 1:1) |
| `paymasterAOA` | `address` | Paymaster address for AOA mode (optional, use address(0) for AOA+ only) |

| returns | type | description |
|---|---|---|
| `token` | `address` | Deployed token address |

#### `getAllTokens()`

`0x2a5c792a` · view · access: —

> Get all deployed tokens

| returns | type | description |
|---|---|---|
| `tokens` | `address[]` | Array of token addresses |

#### `getAPNTsPrice()`

`0x59734e1a` · view · access: —

> Get current aPNTs USD price

*@dev* Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation

| returns | type | description |
|---|---|---|
| `price` | `uint256` | aPNTs price in USD (18 decimals) |

#### `getDeployedCount()`

`0x0ff65414` · view · access: —

> Get total deployed tokens count

| returns | type | description |
|---|---|---|
| `count` | `uint256` | Total count |

#### `getDepositBreakdown(address community)`

`0xbe382cdb` · view · access: —

> Calculate deposit breakdown

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `dailyCost` | `uint256` | Daily cost estimate |
| `monthlyCost` | `uint256` | Monthly cost estimate |
| `suggestedAmount` | `uint256` | Suggested deposit with safety factor |
| `multiplierUsed` | `uint256` | Industry multiplier used |
| `safetyFactorUsed` | `uint256` | Safety factor used |

#### `getIndustryMultiplier(string industry)`

`0xdf9a70ea` · view · access: —

> Get industry multiplier

| param | type | description |
|---|---|---|
| `industry` | `string` | Industry name |

| returns | type | description |
|---|---|---|
| `multiplier` | `uint256` | Multiplier value (scaled by 1e18) |

#### `getPredictionParams(address community)`

`0xae9a6d6f` · view · access: —

> Get prediction parameters for community

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `params` | `(uint256,uint256,uint256,uint256)` | Prediction parameters |

#### `getTokenAddress(address community)`

`0xb8d7b669` · view · access: —

> Get xPNTs token address for community

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `token` | `address` | Token address (address(0) if not deployed) |

#### `hasToken(address community)`

`0x9bb0f599` · view · access: —

> Check if community has deployed token

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `_0` | `bool` | hasToken True if token deployed |

#### `implementation()`

`0x5c60da1b` · view · access: —

> The address of the xPNTsToken implementation contract used for cloning.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `industryMultipliers(string arg0)`

`0xab798449` · view · access: —

> Industry multipliers (name => value in 1e18)

| param | type | description |
|---|---|---|
| `arg0` | `string` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `isXPNTs(address arg0)`

`0x96e28d28` · view · access: —

> Whitelist of tokens this factory has deployed.

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `MIN_SUGGESTED_AMOUNT()`

`0x8dbb03b1` · view · access: —

> Minimum suggested amount: 100 aPNTs

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

*@dev* Returns the address of the current owner.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `predictDepositAmount(address community)`

`0xb2bcfd34` · view · access: —

> AI-powered deposit amount prediction

| param | type | description |
|---|---|---|
| `community` | `address` | Community address |

| returns | type | description |
|---|---|---|
| `suggestedAmount` | `uint256` | Suggested deposit amount in aPNTs |

#### `predictions(address arg0)`

`0x35fa61fa` · view · access: —

> Mapping: community address => prediction parameters

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `avgDailyTx` | `uint256` |  |
| `avgGasCost` | `uint256` |  |
| `industryMultiplier` | `uint256` |  |
| `safetyFactor` | `uint256` |  |

#### `propagateSuperPaymaster(uint256 start, uint256 limit)`

`0x67d7bc06` · nonpayable · access: onlyOwner

> Propagate current SUPERPAYMASTER address to a batch of deployed tokens.

*@dev* Best-effort: failures emit SuperPaymasterPropagationFailed without reverting.      Call repeatedly with increasing `start` to handle large deployedTokens arrays      and to retry previously failed tokens.

| param | type | description |
|---|---|---|
| `start` | `uint256` | Index in deployedTokens to start from (inclusive). |
| `limit` | `uint256` | Maximum number of tokens to process in this call. |

#### `REGISTRY()`

`0x06433b1b` · view · access: —

> Registry contract address

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `renounceOwnership()`

`0x715018a6` · nonpayable · access: —

*@dev* Leaves the contract without owner. It will not be possible to call `onlyOwner` functions. Can only be called by the current owner. NOTE: Renouncing ownership will leave the contract without an owner, thereby disabling any functionality that is only available to the owner.

#### `setIndustryMultiplier(string industry, uint256 multiplier)`

`0xa5509758` · nonpayable · access: onlyOwner

> Set industry multiplier (only owner)

| param | type | description |
|---|---|---|
| `industry` | `string` | Industry name |
| `multiplier` | `uint256` | Multiplier value (scaled by 1e18) |

#### `setSuperPaymasterAddress(address _superPaymaster)`

`0x7ade132c` · nonpayable · access: onlyOwner

*@dev* M-8: stores new SP address only; use propagateSuperPaymaster() to push to deployed tokens (OOG-safe batched approach).

| param | type | description |
|---|---|---|
| `_superPaymaster` | `address` |  |

#### `SUPERPAYMASTER()`

`0x5ae48ba4` · view · access: —

> SuperPaymaster contract address

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `transferOwnership(address newOwner)`

`0xf2fde38b` · nonpayable · access: —

*@dev* Transfers ownership of the contract to a new account (`newOwner`). Can only be called by the current owner.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `updateAPNTsPrice(uint256 newPrice)`

`0x2598c32a` · nonpayable · access: onlyOwner

*@dev* P0-12: absolute bounds + ±30% per-tx delta to prevent price manipulation.

| param | type | description |
|---|---|---|
| `newPrice` | `uint256` |  |

#### `updatePrediction(uint256 avgDailyTx, uint256 avgGasCost, string industry, uint256 safetyFactor)`

`0x358064a8` · nonpayable · access: —

> Update prediction parameters

| param | type | description |
|---|---|---|
| `avgDailyTx` | `uint256` | Average daily transactions |
| `avgGasCost` | `uint256` | Average gas cost in wei |
| `industry` | `string` | Industry type (e.g., "DeFi", "Gaming") |
| `safetyFactor` | `uint256` | Safety factor (scaled by 1e18, default 1.5e18) |

#### `updatePredictionCustom(uint256 avgDailyTx, uint256 avgGasCost, uint256 customMultiplier, uint256 safetyFactor)`

`0x382c8036` · nonpayable · access: —

> Update prediction with custom multiplier

| param | type | description |
|---|---|---|
| `avgDailyTx` | `uint256` | Average daily transactions |
| `avgGasCost` | `uint256` | Average gas cost in wei |
| `customMultiplier` | `uint256` | Custom industry multiplier (scaled by 1e18) |
| `safetyFactor` | `uint256` | Safety factor (scaled by 1e18) |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0xfcc60d1b1dedb59d33b8eef97db5a70c8f8f8523c70d6a027dbf676f1290f8d2` | `APNTsPriceUpdated(uint256,uint256)` |
| `0x4bea76f3309d60543efdcea3904bba05cd2c7a2e58668e7de988d525fd6a3f96` | `IndustryMultiplierSet(string,uint256)` |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` |
| `0x2b4eaa806f1ef4367c0f395b151c87df87dcd9a99bdfa956df2e02a9a24d805e` | `PredictionUpdated(address,uint256)` |
| `0x8c48ef656e85255b7e51330f2d5bca7663b2f2f34d2d812c43f780c7c852fd17` | `SuperPaymasterAddressUpdated(address,address)` |
| `0x41c3159aaba10d821e771f08c4f9f3370426fd58cb304fdbd96b5b9e75c872d1` | `SuperPaymasterPropagated(address,address)` |
| `0x5d4bb2355e56aab4ce3c351d050e2a54fb3096e84130577503d5f4b940e0e59e` | `SuperPaymasterPropagationFailed(address,address)` |
| `0xabfc2cb9c596be68324e2badae1694b9003727b1c82695e6c2cfa7ad8a587592` | `xPNTsTokenDeployed(address,address,string,string)` |

### Errors

| selector | error |
|---|---|
| `0x29ab51bf` | `AlreadyDeployed(address)` |
| `0x1e82e519` | `CallerNotCommunity()` |
| `0xc2f868f4` | `ERC1167FailedCreateClone()` |
| `0x8e4c8aa6` | `InvalidAddress(address)` |
| `0x6f12f3dc` | `InvalidMultiplier()` |
| `0xe5239090` | `InvalidParameters()` |
| `0x00bfc921` | `InvalidPrice()` |
| `0x1e4fbdf7` | `OwnableInvalidOwner(address)` |
| `0x118cdaa7` | `OwnableUnauthorizedAccount(address)` |

## xPNTsToken

- **Source:** `contracts/src/tokens/xPNTsToken.sol`
- **Functions:** 61 · **Events:** 18 · **Errors:** 36
- **Title:** xPNTsToken
- Community points token with pre-authorization mechanism

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x819c2ff8` | `addApprovedFacilitator(address)` | nonpayable | — | Authorize a facilitator to invoke         `SuperPaymaster.settleX402PaymentDirect` against this xPNTs. |
| `0xaae64da2` | `addAutoApprovedSpender(address)` | nonpayable | onlyFactoryOrOwner | Add an address (e.g. SuperPaymaster) that can spend tokens without explicit approval. |
| `0xdd62ed3e` | `allowance(address,address)` | view | — | Override allowance() to implement pre-authorization |
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0xeca9f014` | `approvedFacilitators(address)` | view | — | Community-controlled whitelist of x402 facilitators. |
| `0xf1d85d55` | `autoApprovedSpenders(address)` | view | — | Pre-authorized spenders (no approve needed) |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x9dc29fac` | `burn(address,uint256)` | nonpayable | — | Burn `amount` tokens from `from`. When `msg.sender != from`,         allowance must be sufficient AND the spender's per-day burn         cap (P0-8) must not be exceeded. |
| `0x42966c68` | `burn(uint256)` | nonpayable | — |  |
| `0xb83aa2de` | `burnFromWithOpHash(address,uint256,bytes32)` | nonpayable | — | The ONLY function the SuperPaymaster can call to deduct funds. |
| `0x66b48f91` | `communityENS()` | view | — | Community ENS domain |
| `0xc6d572ae` | `communityName()` | view | — | Community name |
| `0x38518bfe` | `communityOwner()` | view | — | Community owner/admin address |
| `0x2ecd4e7d` | `debts(address)` | view | — | User debt balance in aPNTs (protocol unit; converted to xPNTs at settlement) |
| `0x313ce567` | `decimals()` | view | — |  |
| `0x3644e515` | `DOMAIN_SEPARATOR()` | view | — |  |
| `0x84b0196e` | `eip712Domain()` | view | — |  |
| `0xae8866d9` | `emergencyDisabled()` | view | — | One-shot emergency switch. While true, every burn path that         can affect another holder's balance is blocked, including the         SuperPaymaster `burnFromWithOpHash` / `recordDebt` paths and         the autoApproved-spender `burn(address,uint256)` path. Users         can still self-burn their own balance via `burn(uint256)`. |
| `0x20b05859` | `emergencyRevokedAddress()` | view | — | The SuperPaymaster address that was active when         `emergencyRevokePaymaster` was last called. |
| `0x25073b3a` | `emergencyRevokePaymaster()` | nonpayable | — | Halt every burn-shaped path that can touch another holder's         balance. Used when the SuperPaymaster (or an autoApproved         spender) is suspected of being compromised. |
| `0xc1550b28` | `EXCHANGE_RATE_COOLDOWN()` | view | — | P1-14: minimum time between consecutive `updateExchangeRate` calls.         Prevents rapid sequential updates that compound the +/-20% delta         cap and move the rate far from its starting value within a short         window. A 1-hour cooldown limits drift to ~20% per hour. |
| `0x00ef5f4f` | `EXCHANGE_RATE_DELTA_BPS()` | view | — |  |
| `0xaf43e2d1` | `EXCHANGE_RATE_MAX()` | view | — |  |
| `0x7c3c26e6` | `EXCHANGE_RATE_MIN()` | view | — | P0-11: bounds for `updateExchangeRate`. The xPNTs:aPNTs rate         is conceptually anchored to community service value, but         deploys vary widely. Allow 4 orders of magnitude on either         side of the 1:1 default and cap per-update drift to ±20%         (looser than SP's ±10% because per-community rates legitimately         move more than the protocol unit scale). |
| `0x3ba0b9a9` | `exchangeRate()` | view | — | Exchange rate with aPNTs (18 decimals, 1e18 = 1:1) |
| `0xd5f6e0dd` | `exchangeRateUpdatedAt()` | view | — | P1-14: timestamp of the last `updateExchangeRate` call.         0 means the rate has never been updated since initialization.         Used with `EXCHANGE_RATE_COOLDOWN` to enforce a minimum gap         between sequential rate updates. |
| `0x2dd31000` | `FACTORY()` | view | — | Factory contract that deployed this token |
| `0x9a78e72e` | `getDebt(address)` | view | — |  |
| `0x7a5b4f59` | `getMetadata()` | view | — |  |
| `0xf0ce3dd2` | `initialize(string,string,address,string,string,uint256)` | nonpayable | initializer | Initialize token (replaces constructor for clone pattern) |
| `0xb8441cd6` | `MAX_SINGLE_TX_LIMIT_CAP()` | view | — |  |
| `0x2d6f3a3a` | `maxSingleTxLimit()` | view | — | Maximum allowed single transaction amount in aPNTs (anti-bug safeguard) |
| `0x40c10f19` | `mint(address,uint256)` | nonpayable | onlyFactoryOrOwner |  |
| `0x06fdde03` | `name()` | view | — |  |
| `0x8d074547` | `needsApproval(address,address,uint256)` | view | — |  |
| `0x7ecebe00` | `nonces(address)` | view | — |  |
| `0xd505accf` | `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | nonpayable | — |  |
| `0xfa74542d` | `recordDebt(address,uint256)` | nonpayable | — | Record user debt in aPNTs (only SuperPaymaster).         All internal accounting uses aPNTs; xPNTs conversion happens at settlement. |
| `0x30f53441` | `recordDebtWithOpHash(address,uint256,bytes32)` | nonpayable | — | Record user debt in aPNTs with opHash replay protection (P1-17). |
| `0x8501dd1b` | `removeApprovedFacilitator(address)` | nonpayable | — | Revoke a facilitator's authorization (instant, no timelock). |
| `0xc504e209` | `removeAutoApprovedSpender(address)` | nonpayable | — |  |
| `0xd49bdad0` | `renounceFactory()` | nonpayable | — | Allow community owner to cut off Factory's management power |
| `0x6b09de45` | `repayDebt(uint256)` | nonpayable | — | Manually repay debt by burning xPNTs. |
| `0x4e4852f3` | `setMaxSingleTxLimit(uint256)` | nonpayable | — | P1-16: update the owner-configurable single-tx limit. |
| `0x1eb6ca03` | `setSpenderDailyCap(uint256)` | nonpayable | — | P0-8: tune the per-spender daily burn cap. |
| `0x7ade132c` | `setSuperPaymasterAddress(address)` | nonpayable | — | Sets or updates the trusted SuperPaymaster address. |
| `0xbf855565` | `spenderDailyCapTokens()` | view | — | Maximum xPNTs that any non-self spender can burn per rolling 24h window. |
| `0xda21d73e` | `spenderRateLimit(address)` | view | — |  |
| `0x5054dbd0` | `SUPERPAYMASTER_ADDRESS()` | view | — | The address of the trusted SuperPaymaster, which can call special functions. |
| `0x95d89b41` | `symbol()` | view | — |  |
| `0x18160ddd` | `totalSupply()` | view | — |  |
| `0xa9059cbb` | `transfer(address,uint256)` | nonpayable | — |  |
| `0x4000aea0` | `transferAndCall(address,uint256,bytes)` | nonpayable | nonReentrant | Transfer tokens to a contract and call onTransferReceived with data |
| `0x1296ee62` | `transferAndCall(address,uint256)` | nonpayable | nonReentrant | Transfer tokens to a contract and call onTransferReceived |
| `0x623330ae` | `transferCommunityOwnership(address)` | nonpayable | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — | Secure TransferFrom with firewall and single-tx limit |
| `0x027e6d67` | `unsetEmergencyDisabled()` | nonpayable | — | Clear the emergency switch after the community has rotated         the SuperPaymaster (via `setSuperPaymasterAddress`) and is         ready to resume normal operation. |
| `0xb9e205ae` | `updateExchangeRate(uint256)` | nonpayable | onlyFactoryOrOwner | Update the xPNTs:aPNTs exchange rate. |
| `0x3258f045` | `usedDebtHashes(bytes32)` | view | — | P1-17: opHash replay guard for the recordDebt fallback path.         Prevents double-debt when the burnFromWithOpHash path fails         (e.g. insufficient balance) and recordDebtWithOpHash is called         more than once for the same UserOp — which can happen if the         EntryPoint invariant is violated or a future code path retries. |
| `0x7fd6327a` | `usedOpHashes(bytes32)` | view | — | Ensures a UserOperation hash is only used once for payment. |
| `0x54fd4d50` | `version()` | pure | — | Get human-readable version string |

### Functions

#### `addApprovedFacilitator(address facilitator)`

`0x819c2ff8` · nonpayable · access: —

> Authorize a facilitator to invoke         `SuperPaymaster.settleX402PaymentDirect` against this xPNTs.

*@dev* P0-12b (D4): community-controlled whitelist; only community         owner can add/remove. AAStar's default facilitator is NOT         auto-added by the factory — each community decides explicitly.         A facilitator that is not in this set will be rejected by         SuperPaymaster regardless of its `ROLE_PAYMASTER_SUPER` role.Role separation: `approvedFacilitators` gates settle-call invocation         only. The actual `transferFrom` inside `settleX402PaymentDirect` is         executed by the SuperPaymaster contract (msg.sender = SP), which is         already in `autoApprovedSpenders` via factory setup. Facilitators do         NOT need to be in `autoApprovedSpenders` for the settle flow to work.SECURITY: communityOwner MUST be a multisig wallet (e.g., Gnosis Safe).      A compromised single-EOA communityOwner can add arbitrary facilitators,      enabling unauthorized token extraction. This contract cannot enforce      multisig — the deployment process must ensure communityOwner != EOA.Prevents communityOwner from acting as both administrator and facilitator      (conflict of interest: an owner-facilitator could exploit the auto-approved      allowance they administer, bypassing the separation-of-duties guarantee).

| param | type | description |
|---|---|---|
| `facilitator` | `address` | Facilitator address to approve. |

#### `addAutoApprovedSpender(address spender)`

`0xaae64da2` · nonpayable · access: onlyFactoryOrOwner

> Add an address (e.g. SuperPaymaster) that can spend tokens without explicit approval.

| param | type | description |
|---|---|---|
| `spender` | `address` |  |

#### `allowance(address owner, address spender)`

`0xdd62ed3e` · view · access: —

> Override allowance() to implement pre-authorization

*@dev* Auto-approved spenders have unlimited allowance, protected by firewall and single-tx limit

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `approve(address spender, uint256 value)`

`0x095ea7b3` · nonpayable · access: —

*@dev* See {IERC20-approve}. NOTE: If `value` is the maximum `uint256`, the allowance is not updated on `transferFrom`. This is semantically equivalent to an infinite approval. Requirements: - `spender` cannot be the zero address.

| param | type | description |
|---|---|---|
| `spender` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `approvedFacilitators(address arg0)`

`0xeca9f014` · view · access: —

> Community-controlled whitelist of x402 facilitators.

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `autoApprovedSpenders(address arg0)`

`0xf1d85d55` · view · access: —

> Pre-authorized spenders (no approve needed)

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `balanceOf(address account)`

`0x70a08231` · view · access: —

*@dev* See {IERC20-balanceOf}.

| param | type | description |
|---|---|---|
| `account` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `burn(address from, uint256 amount)`

`0x9dc29fac` · nonpayable · access: —

> Burn `amount` tokens from `from`. When `msg.sender != from`,         allowance must be sufficient AND the spender's per-day burn         cap (P0-8) must not be exceeded.

*@dev* Security history:         - P0-7 (B4-H1): community emergency switch halts all third-party burns.         - P0-8 (B4-H2): spender path now uses canonical _spendAllowance           (instead of hand-rolled allowance arithmetic). Combined with           the per-spender daily rate limit, this closes the           "compromised facilitator drains many holders within           MAX_SINGLE_TX_LIMIT bursts" vector documented in T-14.         The autoApproved spender semantics are preserved: holders         still pay zero approval gas (allowance() returns max), but the         spender's cumulative burn is bounded by spenderDailyCapTokens.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `amount` | `uint256` |  |

#### `burn(uint256 amount)`

`0x42966c68` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `amount` | `uint256` |  |

#### `burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32 userOpHash)`

`0xb83aa2de` · nonpayable · access: —

> The ONLY function the SuperPaymaster can call to deduct funds.

| param | type | description |
|---|---|---|
| `from` | `address` | The user's address to burn tokens from. |
| `amountAPNTs` | `uint256` | The aPNTs amount to settle; converted to xPNTs internally        using: xPNTs = ceil(amountAPNTs * exchangeRate / 1e18). |
| `userOpHash` | `bytes32` | The unique hash of the UserOperation, preventing replays. |

#### `communityENS()`

`0x66b48f91` · view · access: —

> Community ENS domain

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `communityName()`

`0xc6d572ae` · view · access: —

> Community name

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `communityOwner()`

`0x38518bfe` · view · access: —

> Community owner/admin address

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `debts(address arg0)`

`0x2ecd4e7d` · view · access: —

> User debt balance in aPNTs (protocol unit; converted to xPNTs at settlement)

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `decimals()`

`0x313ce567` · view · access: —

*@dev* Returns the number of decimals used to get its user representation. For example, if `decimals` equals `2`, a balance of `505` tokens should be displayed to a user as `5.05` (`505 / 10 ** 2`). Tokens usually opt for a value of 18, imitating the relationship between Ether and Wei. This is the default value returned by this function, unless it's overridden. NOTE: This information is only used for _display_ purposes: it in no way affects any of the arithmetic of the contract, including {IERC20-balanceOf} and {IERC20-transfer}.

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `DOMAIN_SEPARATOR()`

`0x3644e515` · view · access: —

*@dev* Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `eip712Domain()`

`0x84b0196e` · view · access: —

*@dev* See {IERC-5267}.

| returns | type | description |
|---|---|---|
| `fields` | `bytes1` |  |
| `name` | `string` |  |
| `version` | `string` |  |
| `chainId` | `uint256` |  |
| `verifyingContract` | `address` |  |
| `salt` | `bytes32` |  |
| `extensions` | `uint256[]` |  |

#### `emergencyDisabled()`

`0xae8866d9` · view · access: —

> One-shot emergency switch. While true, every burn path that         can affect another holder's balance is blocked, including the         SuperPaymaster `burnFromWithOpHash` / `recordDebt` paths and         the autoApproved-spender `burn(address,uint256)` path. Users         can still self-burn their own balance via `burn(uint256)`.

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `emergencyRevokedAddress()`

`0x20b05859` · view · access: —

> The SuperPaymaster address that was active when         `emergencyRevokePaymaster` was last called.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `emergencyRevokePaymaster()`

`0x25073b3a` · nonpayable · access: —

> Halt every burn-shaped path that can touch another holder's         balance. Used when the SuperPaymaster (or an autoApproved         spender) is suspected of being compromised.

*@dev* P0-7: previously only cleared `autoApprovedSpenders[currentSP]`,         which left `burnFromWithOpHash` and `recordDebt` reachable from         the compromised SP because those gates check         `msg.sender == SUPERPAYMASTER_ADDRESS` directly. Flipping the         `emergencyDisabled` flag closes all dangerous paths in one tx.SECURITY: communityOwner SHOULD be a multisig. A compromised EOA      communityOwner could call unsetEmergencyDisabled() immediately before      emergencyRevokePaymaster(), bypassing the emergency circuit breaker.      Deploy with communityOwner = Gnosis Safe or equivalent multisig.

#### `EXCHANGE_RATE_COOLDOWN()`

`0xc1550b28` · view · access: —

> P1-14: minimum time between consecutive `updateExchangeRate` calls.         Prevents rapid sequential updates that compound the +/-20% delta         cap and move the rate far from its starting value within a short         window. A 1-hour cooldown limits drift to ~20% per hour.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `EXCHANGE_RATE_DELTA_BPS()`

`0x00ef5f4f` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `EXCHANGE_RATE_MAX()`

`0xaf43e2d1` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `EXCHANGE_RATE_MIN()`

`0x7c3c26e6` · view · access: —

> P0-11: bounds for `updateExchangeRate`. The xPNTs:aPNTs rate         is conceptually anchored to community service value, but         deploys vary widely. Allow 4 orders of magnitude on either         side of the 1:1 default and cap per-update drift to ±20%         (looser than SP's ±10% because per-community rates legitimately         move more than the protocol unit scale).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `exchangeRate()`

`0x3ba0b9a9` · view · access: —

> Exchange rate with aPNTs (18 decimals, 1e18 = 1:1)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `exchangeRateUpdatedAt()`

`0xd5f6e0dd` · view · access: —

> P1-14: timestamp of the last `updateExchangeRate` call.         0 means the rate has never been updated since initialization.         Used with `EXCHANGE_RATE_COOLDOWN` to enforce a minimum gap         between sequential rate updates.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `FACTORY()`

`0x2dd31000` · view · access: —

> Factory contract that deployed this token

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getDebt(address user)`

`0x9a78e72e` · view · access: —

| param | type | description |
|---|---|---|
| `user` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getMetadata()`

`0x7a5b4f59` · view · access: —

| returns | type | description |
|---|---|---|
| `_name` | `string` |  |
| `_symbol` | `string` |  |
| `_communityName` | `string` |  |
| `_communityENS` | `string` |  |
| `_communityOwner` | `address` |  |

#### `initialize(string name_, string symbol_, address _communityOwner, string _communityName, string _communityENS, uint256 _exchangeRate)`

`0xf0ce3dd2` · nonpayable · access: initializer

> Initialize token (replaces constructor for clone pattern)

| param | type | description |
|---|---|---|
| `name_` | `string` | Token name |
| `symbol_` | `string` | Token symbol |
| `_communityOwner` | `address` | Initial owner of the community |
| `_communityName` | `string` | Display name |
| `_communityENS` | `string` | ENS name |
| `_exchangeRate` | `uint256` | aPNTs exchange rate |

#### `MAX_SINGLE_TX_LIMIT_CAP()`

`0xb8441cd6` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `maxSingleTxLimit()`

`0x2d6f3a3a` · view · access: —

> Maximum allowed single transaction amount in aPNTs (anti-bug safeguard)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `mint(address to, uint256 amount)`

`0x40c10f19` · nonpayable · access: onlyFactoryOrOwner

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

#### `name()`

`0x06fdde03` · view · access: —

*@dev* Overridden to return storage variable

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `needsApproval(address owner, address spender, uint256 amount)`

`0x8d074547` · view · access: —

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |
| `amount` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `nonces(address owner)`

`0x7ecebe00` · view · access: —

*@dev* Returns the current nonce for `owner`. This value must be included whenever a signature is generated for {permit}. Every successful call to {permit} increases ``owner``'s nonce by one. This prevents a signature from being used multiple times.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)`

`0xd505accf` · nonpayable · access: —

*@dev* Sets `value` as the allowance of `spender` over ``owner``'s tokens, given ``owner``'s signed approval. IMPORTANT: The same issues {IERC20-approve} has related to transaction ordering also apply here. Emits an {Approval} event. Requirements: - `spender` cannot be the zero address. - `deadline` must be a timestamp in the future. - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner` over the EIP712-formatted function arguments. - the signature must use ``owner``'s current nonce (see {nonces}). For more information on the signature format, see the https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP section]. CAUTION: See Security Considerations above.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `spender` | `address` |  |
| `value` | `uint256` |  |
| `deadline` | `uint256` |  |
| `v` | `uint8` |  |
| `r` | `bytes32` |  |
| `s` | `bytes32` |  |

#### `recordDebt(address user, uint256 amountAPNTs)`

`0xfa74542d` · nonpayable · access: —

> Record user debt in aPNTs (only SuperPaymaster).         All internal accounting uses aPNTs; xPNTs conversion happens at settlement.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `amountAPNTs` | `uint256` |  |

#### `recordDebtWithOpHash(address user, uint256 amountAPNTs, bytes32 opHash)`

`0x30f53441` · nonpayable · access: —

> Record user debt in aPNTs with opHash replay protection (P1-17).

*@dev* Preferred over recordDebt when the UserOp hash is available.         Ensures that if postOp is somehow invoked twice for the same         UserOp (EntryPoint invariant violation), the second call reverts         rather than doubling the user's debt. The burnFromWithOpHash path         already carries opHash replay protection via usedOpHashes; this         function closes the same gap for the balance-insufficient fallback.         SuperPaymaster._recordDebt calls this instead of recordDebt.

| param | type | description |
|---|---|---|
| `user` | `address` |  |
| `amountAPNTs` | `uint256` |  |
| `opHash` | `bytes32` |  |

#### `removeApprovedFacilitator(address facilitator)`

`0x8501dd1b` · nonpayable · access: —

> Revoke a facilitator's authorization (instant, no timelock).

*@dev* P0-12b: incident-response primitive; community can yank a         compromised facilitator without redeploying or upgrading SP.SECURITY: communityOwner MUST be a multisig wallet (e.g., Gnosis Safe).      A compromised single-EOA communityOwner can add arbitrary facilitators,      enabling unauthorized token extraction. This contract cannot enforce      multisig — the deployment process must ensure communityOwner != EOA.

| param | type | description |
|---|---|---|
| `facilitator` | `address` | Facilitator address to remove. |

#### `removeAutoApprovedSpender(address spender)`

`0xc504e209` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `spender` | `address` |  |

#### `renounceFactory()`

`0xd49bdad0` · nonpayable · access: —

> Allow community owner to cut off Factory's management power

*@dev* Once renounced, FACTORY can no longer call restricted functions (mint, updateExchangeRate, etc.).      B4-N2: also revokes the old factory's autoApprovedSpender privilege so a renounced or      compromised factory address can no longer burn tokens via the autoApproved path.

#### `repayDebt(uint256 amountXPNTs)`

`0x6b09de45` · nonpayable · access: —

> Manually repay debt by burning xPNTs.

| param | type | description |
|---|---|---|
| `amountXPNTs` | `uint256` | xPNTs to burn; converts to aPNTs = floor(amountXPNTs * 1e18 / rate). |

#### `setMaxSingleTxLimit(uint256 newLimit)`

`0x4e4852f3` · nonpayable · access: —

> P1-16: update the owner-configurable single-tx limit.

*@dev* communityOwner only. `newLimit` must be > 0 and <= MAX_SINGLE_TX_LIMIT_CAP         to prevent a misconfigured or compromised owner from setting an         unbounded limit that negates the single-tx anti-bug safeguard.

| param | type | description |
|---|---|---|
| `newLimit` | `uint256` |  |

#### `setSpenderDailyCap(uint256 newCap)`

`0x1eb6ca03` · nonpayable · access: —

> P0-8: tune the per-spender daily burn cap.

*@dev* Community-owner only. The cap applies to ANY non-self burn —         autoApproved facilitators, manually-approved spenders, etc.         A value of 0 effectively disables third-party burn entirely         (every burn would revert SpenderDailyCapExceeded).         The cap must not exceed type(uint128).max because         `SpenderRateLimit.dailyBurnTotal` is stored as uint128;         a larger cap would pass the newTotal > cap check but the         downcast `rl.dailyBurnTotal = uint128(newTotal)` would         truncate and silently reset the counter to 0.

| param | type | description |
|---|---|---|
| `newCap` | `uint256` |  |

#### `setSuperPaymasterAddress(address _spAddress)`

`0x7ade132c` · nonpayable · access: —

> Sets or updates the trusted SuperPaymaster address.

*@dev* Normal mode: factory or communityOwner may call this.         Emergency mode (`emergencyDisabled == true`): only `communityOwner`         may call. The factory is blocked because the emergency switch is         designed to give the community — not the factory — exclusive control         over recovery. Letting FACTORY rotate the SP during an active         emergency would allow an entity that may itself be compromised to         re-introduce a malicious paymaster while the community thinks the         token is frozen.

| param | type | description |
|---|---|---|
| `_spAddress` | `address` |  |

#### `spenderDailyCapTokens()`

`0xbf855565` · view · access: —

> Maximum xPNTs that any non-self spender can burn per rolling 24h window.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `spenderRateLimit(address arg0)`

`0xda21d73e` · view · access: —

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `dailyBurnTotal` | `uint128` |  |
| `windowStart` | `uint64` |  |
| `reserved` | `uint64` |  |

#### `SUPERPAYMASTER_ADDRESS()`

`0x5054dbd0` · view · access: —

> The address of the trusted SuperPaymaster, which can call special functions.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `symbol()`

`0x95d89b41` · view · access: —

*@dev* Overridden to return storage variable

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `totalSupply()`

`0x18160ddd` · view · access: —

*@dev* See {IERC20-totalSupply}.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `transfer(address to, uint256 value)`

`0xa9059cbb` · nonpayable · access: —

*@dev* See {IERC20-transfer}. Requirements: - `to` cannot be the zero address. - the caller must have a balance of at least `value`.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferAndCall(address to, uint256 amount, bytes data)`

`0x4000aea0` · nonpayable · access: nonReentrant

> Transfer tokens to a contract and call onTransferReceived with data

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |
| `data` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferAndCall(address to, uint256 amount)`

`0x1296ee62` · nonpayable · access: nonReentrant

> Transfer tokens to a contract and call onTransferReceived

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferCommunityOwnership(address newOwner)`

`0x623330ae` · nonpayable · access: —

*@dev* The new owner SHOULD be a multisig. See addApprovedFacilitator for security rationale.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `transferFrom(address from, address to, uint256 value)`

`0x23b872dd` · nonpayable · access: —

> Secure TransferFrom with firewall and single-tx limit

*@dev* Auto-approved spenders can only transfer to themselves or current SuperPaymaster

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `unsetEmergencyDisabled()`

`0x027e6d67` · nonpayable · access: —

> Clear the emergency switch after the community has rotated         the SuperPaymaster (via `setSuperPaymasterAddress`) and is         ready to resume normal operation.

*@dev* Recovery flow: `emergencyRevokePaymaster` →         `setSuperPaymasterAddress(newSP)` → `unsetEmergencyDisabled`.         Calling this function before rotating the SP address reverts         with `RecoveryNotComplete` — this prevents the community owner         from accidentally re-trusting the compromised address.SECURITY: communityOwner SHOULD be a multisig. A compromised EOA      communityOwner could call unsetEmergencyDisabled() immediately before      emergencyRevokePaymaster(), bypassing the emergency circuit breaker.      Deploy with communityOwner = Gnosis Safe or equivalent multisig.

#### `updateExchangeRate(uint256 _newRate)`

`0xb9e205ae` · nonpayable · access: onlyFactoryOrOwner

> Update the xPNTs:aPNTs exchange rate.

*@dev* P0-11 (B4-M2): pre-fix only checked `_newRate != 0`. Inline      bounds (absolute MIN/MAX + ±20% per-tx drift) bound the blast of      a misclick or compromised factory/owner. Delta check skipped on      the first set (the constructor default of 1e18 means oldRate is      already non-zero in practice; the guard is for robustness).

| param | type | description |
|---|---|---|
| `_newRate` | `uint256` |  |

#### `usedDebtHashes(bytes32 arg0)`

`0x3258f045` · view · access: —

> P1-17: opHash replay guard for the recordDebt fallback path.         Prevents double-debt when the burnFromWithOpHash path fails         (e.g. insufficient balance) and recordDebtWithOpHash is called         more than once for the same UserOp — which can happen if the         EntryPoint invariant is violated or a future code path retries.

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `usedOpHashes(bytes32 arg0)`

`0x7fd6327a` · view · access: —

> Ensures a UserOperation hash is only used once for payment.

| param | type | description |
|---|---|---|
| `arg0` | `bytes32` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `version()`

`0x54fd4d50` · pure · access: —

> Get human-readable version string

| returns | type | description |
|---|---|---|
| `_0` | `string` | versionString The version string (e.g., "v3.1.0") |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0xcd244ccee31904b178ff7bfc95631cea7812a955f9a330ac216c0c8c9dbfaf20` | `AutoApprovedSpenderAdded(address)` |
| `0x49debedb360a6c155dc3046b522ec5e27906afea1be0015b4625302e9192e2d8` | `AutoApprovedSpenderRemoved(address)` |
| `0x1191f7dd7e510e69e54c21c704f6f3c1179351c8a1a8d6a2a66d1e20aed6fd0f` | `CommunityOwnerUpdated(address,address)` |
| `0x99cf5cc1e3146bd15204f8eae4fe16c690d6123fbdac32515502fe688b86b8f5` | `DebtRecorded(address,uint256)` |
| `0x798353030d4251a345706609acf9ea7527f2ace26f73150a098c0fae89e5886d` | `DebtRepaid(address,uint256,uint256)` |
| `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` | `EIP712DomainChanged()` |
| `0x56a64ec95bb93ae6af923c082ef9ab2bd5bdd6f1a121c45e8c05a39ab73bbf06` | `EmergencyDisabledCleared(address)` |
| `0x51745cdc5b4ed1fe5c20c1cbf61290785ef5df0cb643101a29618bed23d8305c` | `EmergencyDisabledSet(address)` |
| `0xc8d1043f24843c0a1c9251fdc30017d84e87498fbcf232af9f86816b5e182bde` | `ExchangeRateUpdated(uint256,uint256)` |
| `0x14b842314c1bed1881a6aaf3371cb59429fa3f849dbd8ad0698501dc4aa0574c` | `FacilitatorApproved(address)` |
| `0xa8fe5b89f35f2ebd6f3f95a7ef215f4bd89179e10c101073ae76cffad14734cf` | `FacilitatorRemoved(address)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0xfabe53bf01983df9c24aab2e57a83e6f8a69975380cf9bd0811dd2f431ac4d46` | `MaxSingleTxLimitUpdated(uint256,uint256)` |
| `0x68639863c58fa667262fab7192372355b1b2cb2731dcd7636cedbfcd1900f05d` | `SpenderDailyCapUpdated(uint256,uint256)` |
| `0xbee963043b15401a5f01418733a5739b29c9d9e128ecfadc5b2078bffe8ba917` | `SpenderRateLimitWindowReset(address,uint64)` |
| `0x3c84f1b682ac1493ee72abc0427a570b681583551f8fadd1b98ea9cce545ec6a` | `SuperPaymasterAddressUpdated(address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x07df4537` | `BurnExceedsAllowance()` |
| `0x588569f7` | `BurnExceedsBalance()` |
| `0x9ce0e962` | `DebtAlreadyRecorded(bytes32)` |
| `0xf645eedf` | `ECDSAInvalidSignature()` |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256)` |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32)` |
| `0x4e97bcfc` | `EmergencyStop()` |
| `0xfb8f41b2` | `ERC20InsufficientAllowance(address,uint256,uint256)` |
| `0xe450d38c` | `ERC20InsufficientBalance(address,uint256,uint256)` |
| `0xe602df05` | `ERC20InvalidApprover(address)` |
| `0xec442f05` | `ERC20InvalidReceiver(address)` |
| `0x96c6fd1e` | `ERC20InvalidSender(address)` |
| `0x94280d62` | `ERC20InvalidSpender(address)` |
| `0x62791302` | `ERC2612ExpiredSignature(uint256)` |
| `0x4b800e46` | `ERC2612InvalidSigner(address,address)` |
| `0x150c57e5` | `ExchangeRateCannotBeZero()` |
| `0x91bd60f2` | `ExchangeRateCooldownActive()` |
| `0xbba592ba` | `ExchangeRateDeltaTooLarge(uint256,uint256,uint256)` |
| `0x34607448` | `ExchangeRateOutOfRange(uint256,uint256,uint256)` |
| `0x752d88c0` | `InvalidAccountNonce(address,uint256)` |
| `0x8e4c8aa6` | `InvalidAddress(address)` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0xd2529034` | `InvalidParam()` |
| `0xb3512b0c` | `InvalidShortString()` |
| `0x5a0a27b2` | `MustUseBurnFromWithOpHash()` |
| `0x54641f00` | `NoDebtToRepay()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0xe18b4060` | `OperationAlreadyProcessed(bytes32)` |
| `0xfeffcf0a` | `RecoveryNotComplete()` |
| `0xe31d04ea` | `RepayExceedsDebt()` |
| `0x2c1032b5` | `SingleTxLimitExceeded()` |
| `0xc4fae443` | `SpenderDailyCapExceeded(address,uint256,uint256)` |
| `0x305a27a9` | `StringTooLong(string)` |
| `0xb68ac504` | `SuperPaymasterNotConfigured()` |
| `0x8e4a23d6` | `Unauthorized(address)` |
| `0x9405c086` | `UnauthorizedRecipient()` |

## BLS

- **Source:** `contracts/src/utils/BLS.sol`
- **Functions:** 0 · **Events:** 0 · **Errors:** 7
- BLS wrapper.

### Errors

| selector | error |
|---|---|
| `0xd6cc76eb` | `G1AddFailed()` |
| `0x5f776986` | `G1MSMFailed()` |
| `0xc55e5e33` | `G2AddFailed()` |
| `0xe3dc5425` | `G2MSMFailed()` |
| `0x89083b91` | `MapFp2ToG2Failed()` |
| `0x24a289fc` | `MapFpToG1Failed()` |
| `0x4df45e2f` | `PairingFailed()` |
