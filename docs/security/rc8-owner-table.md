# rc.8 owner / role table — v0

Sepolia current state, read-only, Alchemy archive, blocks 12153562–12153596 (2026-11-17), plus the source survey.

**Notation**
- **D** = deployer EOA `0xb5600060e6de5E11D3636731964218E53caadf0E`
- **SAFE** = manifest Safe `0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` (2-of-3)
- **TL48** = new TimelockController `0xccdf8e0d…c34b`, `minDelay` 172800. Proposer, executor and canceller = SAFE; admin = itself only.
- **oldTL** = `0x86C86c…9564`, `minDelay` 172800. **D holds proposer, executor, canceller and admin.**

Planned rc.8 transfers in `manifest_exec` (`handover_contracts`):
- to TL48: SP (A17), Registry (D stage, two-step, accepted through TL48), AOAProtocolRegistry, xPNTsFactoryV2;
- to SAFE: BLSAggregator (and its `slashPolicyAdmin`), DVTValidator, committee, the old aggregator;
- APNTsCapped is deployed by a3a with TL48 as owner.

## A. Owners

| Contract | Address | Sepolia owner now | Planned after rc.8 | Manifest step | Status |
|---|---|---|---|---|---|
| SuperPaymaster (proxy) | 0x09DF… | D | TL48 | A17 | planned |
| Registry (proxy) | 0xf5Bf… | D | TL48 | D.registry two-step | planned |
| BLSAggregator 4.11.0 (old) | 0xEaeC… | D | SAFE | D.old_aggregator | planned |
| BLSAggregator 4.3.0 (prev-prev) | 0x174b… | D | — | none | **gap** |
| DVTValidator 0.6.0 | 0x568b… | D | SAFE (new DVT via A7.dvt) | D.dvt | planned for the old DVT; new DVT pending A7.dvt |
| committee | 0x7ac7… | D | SAFE | D.committee | planned |
| GTokenStaking | 0x4722… | D | TL48/SAFE? | none | **gap (tag blocker)** |
| GToken | 0x4c09… | D (owner is also the minter) | ? | none | **gap** |
| MySBT | 0x4867… | no owner; `daoMultisig` = D | ? | none | **gap** |
| xPNTsFactory v1 | 0x6742… | D | ? | none | **gap** |
| ReputationSystem 0.3.2 | 0x4Ec2… | D | ? (0.6.0 is a fresh deploy) | none | **gap** |
| PaymasterFactory | 0xA936… | D | ? | none | **gap** |
| PaymasterV4 impl, aPNTs PMV4 | 0xa468…, 0xf394… | D | ? | none | **gap** |
| pNTs PMV4 | 0xC827… | 0xEcAA… (Mycelium operator) | unchanged | — | community-owned |
| MicroPaymentChannel | 0x3757… | D | ? | none | **gap** (tool contract) |
| X402Facilitator | 0xfe1D… | D | ? | none | **gap** (tool contract) |
| LivenessRegistry | 0x02d8… | D | ? | none | **gap** |
| xPNTsFactoryCC28 | 0x9f42… | D | ? | none | **gap** (test factory) |
| PolicyRegistry | 0x2925… | no owner; `timelock` = oldTL (immutable); `guardian` = D | ? | none | **gap**: governed through oldTL, which D controls |
| oldTL | 0x86C8… | roles all held by D | renounce / leave idle? | none | **gap** |
| aPNTs (xPNTs v1) | 0x696A… | `communityOwner` 0x51C0…; `FACTORY` = xPNTsFactory v1 | — | — | community |
| pNTs (xPNTs v1) | 0xE657… | `communityOwner` 0xEcAA…; `FACTORY` = v1 | — | — | community |

## B. Non-owner privileges held by D (none of them move with ownership — survey)

| Contract | Privilege | Getter | Sepolia now | Revocation | In the manifest? |
|---|---|---|---|---|---|
| Registry | `isReputationSource[D]` (`initialize`, `Registry.sol:172`) | `isReputationSource(address)` | **true** | `setReputationSource(D,false)` | **no** |
| Registry | `roleConfigs[id].owner` for all 7 roles (`initialize`, via `_initRole`); `configureRole` lets the role owner rewrite `minStake`, ticket price, slash parameters, exit fee, `isActive` and the role owner itself | `getRoleConfig(bytes32).owner` | **D for COMMUNITY, ENDUSER, PAYMASTER_AOA, PAYMASTER_SUPER, DVT, ANODE, KMS** | `configureRole(id, cfg with owner = TL48)` × 7 | **no (new, large)** |
| BLSAggregator (old) | `slashPolicyAdmin` (constructor `msg.sender`) | `slashPolicyAdmin()` | D | `setSlashPolicyAdmin(SAFE)` | yes (D.old_aggregator.admin) |
| SuperPaymaster | `treasury` | `treasury()` | D | `setTreasury` | **no** |
| GTokenStaking | `treasury` | `treasury()` | D | `setTreasury` | **no** |
| MySBT | `daoMultisig` | `daoMultisig()` | D | `setDAOMultisig` (onlyDAO) | **no** |
| PolicyRegistry | `guardian` | `guardian()` | D | `setGuardian` (onlyTimelock = oldTL, D controls it) | **no** |
| DVTValidator (old) | `isValidator[D]` | `isValidator(address)` | **true** | `removeValidator` | no (old DVT is replaced by A7.dvt) |
| oldTL | proposer, executor, canceller, admin | `hasRole` | D | `renounceRole` / revoke | **no** |
| SP | `guardian` | `guardian()` | read reverted on 5.4.2 (the getter is new in 5.5.0) | `setGuardian` | check after the upgrade |

## C. Auto-grants at construction or initialization (5.5.0 source, HEAD 02c31f45)

None of these is cleared by an ownership transfer. Only `Ownable2StepNamespaced._transferOwnership` is overridden, and it clears `pendingOwner` only.

- **Registry.initialize**
  - `isReputationSource[_owner]` (`:172`)
  - the 7 `roleConfigs.owner` entries (`:119-121`)
- **BLSAggregator constructor:** `slashPolicyAdmin = msg.sender` (`:709`)
- **SuperPaymaster.initialize:** `treasury = _protocolTreasury`, or `_owner` if it is 0 (`:124`)
- **xPNTsToken v1**
  - `FACTORY = msg.sender`
  - `autoApprovedSpenders[factory]`, cleared by `renounceFactory` or `removeAutoApprovedSpender`
- **xPNTsTokenV2**
  - `FACTORY`
  - `autoApprovedSpenders[genesisSpender]`
  - `historicalSP[sp]`, which has **no clearing setter**
- **APNTsCapped:** owner, `minter`, `capGuardian` from constructor params
- **PolicyRegistry:** immutable `timelock`, `guardian`, `initialConsumer`
- **MySBT:** `daoMultisig`
- **Paymaster V4:** `treasury`
- **`Ownable(msg.sender)`:** GToken, GTokenStaking, xPNTsFactory / V2, ReputationSystem, DVTValidator, X402Facilitator, PaymasterFactory
- **`Ownable(param)`:** AOAProtocolRegistry, LivenessRegistry, MicroPaymentChannel

## D. Readback assertions for step 13

These apply to every row above.
- **No privilege may remain with D.** owner, `pendingOwner`, `roleConfigs.owner`, `isReputationSource`, `slashPolicyAdmin`, treasury, `daoMultisig`, guardian, validator and TL roles must all differ from D, unless a row records an explicit exception with its reason.
- **OWNER-NOT-AGGREGATOR:** no contract owner or role holder equals any aggregator address.
- **AGG-NOT-DVT-VALIDATOR:** no aggregator is a DVT validator.
- **AGG-ZERO-BALANCES:** every aggregator holds zero of every asset.
- **Slashers:** `authorizedSlashers` is false for every aggregator generation.
