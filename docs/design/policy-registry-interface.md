# PolicyRegistry 3.0.1 interface and governance design

> **Status:** Implemented by `contracts/src/core/PolicyRegistry.sol` and
> `contracts/src/interfaces/v3/IPolicyRegistry.sol`.
> **Version:** `PolicyRegistry-3.0.1`.
> **Deployment:** Deployed by the 5.5.0 manifest. No deployment address is assigned yet.

## Purpose

`PolicyRegistry` is a standalone, non-upgradeable policy registry. It evaluates an action identified
by `(sender, target, asset, amount, selector)` and returns `ALLOW`, `REQUIRE_DVT`, or `REJECT`.

The registry keys every policy and counter by `sender`. A staked ERC-4337 consumer can therefore
read the sender-associated state during validation under ERC-7562. Policy limits use native asset
units. The registry has no price oracle and does not inspect signature wire formats.

The default is opt-in. An unconfigured asset and an unconfigured target impose no restrictions.
A frozen sender always receives `REJECT`.

## Data model

### Asset policy

`AssetPolicy` applies to `(sender, asset)`:

```solidity
struct AssetPolicy {
    uint128 dvtTriggerAmount;
    uint128 perTxHardCap;
    uint256 dailyLimit;
    uint64 windowSeconds;
    bool configured;
}
```

For a configured asset, `perTxHardCap` and `dailyLimit` are hard rejection limits.
`dvtTriggerAmount == 0` disables the amount-based DVT trigger. `windowSeconds == 0` uses
`DEFAULT_WINDOW`, which is one day.

### Target-global contract scope

`ContractScope` applies to `(sender, target)`, independent of the asset:

```solidity
struct ContractScope {
    bool allowed;
    bool requireDVTAlways;
    uint64 velocityWindow;
    bool configured;
}
```

The target-global scope controls whether the target is allowed, whether every call requires DVT,
and whether target velocity enforcement is enabled. The selector allowlist is also keyed only by
`(sender, target, selector)`.

`ContractScope` does not contain a velocity limit. The limit is asset-specific:

```solidity
struct TargetVelocity {
    uint128 limit;
    bool configured;
}
```

`TargetVelocity` applies to `(sender, target, asset)`. If a configured target has a nonzero
`velocityWindow`, `checkPolicy` requires a configured velocity entry for the requested asset.
A missing entry fails closed with `REJECT`.

### Counters

Both counters store a `uint256 spentInWindow`:

```solidity
struct SpendCounter {
    uint256 spentInWindow;
    uint64 windowStart;
}

mapping(address sender => mapping(address asset => SpendCounter)) _assetSpend;
mapping(address sender => mapping(address target =>
    mapping(address asset => SpendCounter))) _targetSpend;
```

The asset counter uses the asset policy's `windowSeconds`. The target counter uses the target
scope's `velocityWindow`. When a window has elapsed, the effective spend is zero. `recordSpend`
starts a new window at the current block timestamp before adding the amount.

`recordSpend` advances the asset counter only when the asset policy is configured. It advances the
target counter only when the target scope is configured, its velocity window is nonzero, and the
asset-specific target velocity is configured. A wholly unconfigured tuple changes no counter.
`SpendRecorded` is still emitted.

## Policy decision order

`checkPolicy(address,address,address,uint256,bytes4)` applies these rules:

1. `address(0)` is not a valid asset. ETH uses
   `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
2. A frozen sender returns `REJECT`.
3. If the asset policy is configured, the function enforces the per-transaction cap, the projected
   asset spend, and the amount-based DVT trigger.
4. If the target scope is configured, the function requires `allowed`, requires the selector to be
   allowed, and enforces the asset-specific target velocity when `velocityWindow != 0`.
5. Any failed configured restriction returns `REJECT`. Otherwise, any active DVT trigger returns
   `REQUIRE_DVT`. All other actions return `ALLOW`.

For an unconfigured asset, `remainingDaily` is `type(uint256).max`. For a configured asset, it is
the remaining allowance after the requested amount. A cap rejection returns zero.

## Governance

The contract delegates all delay and proposal state to an external OpenZeppelin
`TimelockController`. PolicyRegistry has no `propose*` functions, `executeProposal`,
`cancelProposal`, `looseningEta`, or `LOOSEN_TIMELOCK`.

The external timelock schedules and executes calls to the `onlyTimelock` functions. The timelock's
`minDelay` supplies the delay. Its `CANCELLER_ROLE` controls cancellation. Because these calls have
already passed through the delayed path, the setters can either loosen or tighten policy.

The guardian or the timelock can use the immediate tightening path:

| Operation | Access | Implemented behavior |
|---|---|---|
| `setAssetPolicy` | timelock only | Replaces the asset policy. |
| `setContractScope` | timelock only | Replaces the target-global scalar fields and adds the listed selectors. It does not clear existing selectors. |
| `setTargetVelocity` | timelock only | Replaces one asset-specific target velocity. |
| `unfreezeSender` | timelock only | Removes a sender freeze. |
| `tightenAssetPolicy` | guardian or timelock | Requires an existing policy. It cannot raise the effective DVT trigger, hard cap, or daily limit. It preserves `windowSeconds`. |
| `tightenContractScope` | guardian or timelock | Requires an existing scope. It cannot newly allow a target or clear `requireDVTAlways`. It preserves `velocityWindow` and removes the listed selectors. |
| `tightenTargetVelocity` | guardian or timelock | Requires an existing velocity entry and cannot raise its limit. |
| `freezeSender` | guardian or timelock | Immediately freezes the sender. |
| `setGuardian` | timelock only | Replaces the guardian with a nonzero address. |
| `setConsumerAuthorization` | timelock only | Grants or revokes permission to call `recordSpend`. |

For `tightenAssetPolicy`, a zero `dvtTriggerAmount` means disabled and is therefore the loosest
value. The immediate path can change zero to a nonzero trigger, but cannot change a nonzero trigger
to zero. For the other two limits, zero is the strictest value.

## Function selectors

The signatures below use canonical ABI tuple syntax. Selectors were computed with
`~/.foundry/bin/cast sig`.

### Reads and execution hooks

| Function signature | Selector | Return type or effect |
|---|---|---|
| `DEFAULT_WINDOW()` | `0x43a0c39f` | `uint64` |
| `ETH_SENTINEL()` | `0xb743be94` | `address` |
| `checkPolicy(address,address,address,uint256,bytes4)` | `0x969cb5da` | `(uint8,uint256)` |
| `recordSpend(address,address,address,uint256,bytes4)` | `0xa1a4a180` | Authorized consumer hook |
| `getAssetPolicy(address,address)` | `0x29210a4b` | `(uint128,uint128,uint256,uint64,bool)` |
| `getTargetScope(address,address)` | `0x7ac0774b` | `(bool,bool,uint64,bool)` |
| `getTargetVelocity(address,address,address)` | `0xcb9fa794` | `(uint128,bool)` |
| `isSelectorAllowed(address,address,bytes4)` | `0xb1655919` | `bool` |
| `getAssetSpend(address,address)` | `0x715904dd` | `(uint256,uint64)` |
| `isFrozen(address)` | `0xe5839836` | `bool` |
| `isAuthorizedConsumer(address)` | `0x7df732ea` | `bool` |
| `guardian()` | `0x452a9320` | `address` |
| `timelock()` | `0xd33219b4` | `address` |
| `version()` | `0x54fd4d50` | `string` |

### Governance mutations

| Function signature | Selector | Access |
|---|---|---|
| `setAssetPolicy(address,address,(uint128,uint128,uint256,uint64))` | `0xbe29f491` | Timelock |
| `setContractScope(address,address,(bool,bool,uint64,bytes4[]))` | `0xc28b58c1` | Timelock |
| `setTargetVelocity(address,address,address,uint128)` | `0xf8f33e86` | Timelock |
| `unfreezeSender(address)` | `0x53d8cb68` | Timelock |
| `tightenAssetPolicy(address,address,(uint128,uint128,uint256,uint64))` | `0x055b8e7b` | Guardian or timelock |
| `tightenContractScope(address,address,(bool,bool,uint64,bytes4[]))` | `0x7f6f42f0` | Guardian or timelock |
| `tightenTargetVelocity(address,address,address,uint128)` | `0xac0a0e81` | Guardian or timelock |
| `freezeSender(address)` | `0x7e19482e` | Guardian or timelock |
| `setGuardian(address)` | `0x8a0dac4a` | Timelock |
| `setConsumerAuthorization(address,bool)` | `0x6ef778ee` | Timelock |

## Event topics

Topic 0 values were computed with `~/.foundry/bin/cast sig-event`.

| Event signature | Indexed fields | Topic 0 |
|---|---|---|
| `AssetPolicySet(address,address,uint128,uint128,uint256,uint64)` | `sender`, `asset` | `0x5d9b9bcdce2cd939b17ac423b2aa97770271ecebda7bf7c45e7db25d980c52ae` |
| `ContractScopeSet(address,address,bool,bool,uint64)` | `sender`, `target` | `0x9da60c6786d525ccc6003f478437c74ad59a8b556fb0fd5dec6dcd6f267c16c2` |
| `TargetVelocitySet(address,address,address,uint128)` | `sender`, `target`, `asset` | `0xa0cc9fdb8f54d3382e30589f0ae0733455166be350b0d2db1aa8e4f2e4b91b21` |
| `SelectorScopeSet(address,address,bytes4,bool)` | `sender`, `target`, `selector` | `0xdae56faaf89f401e21b133aee83453dde734ae5b8d6d672919900921f1e62780` |
| `PolicyTightened(address,address)` | `sender`, `actor` | `0x4d156b5f26f59392a109b67021b0a170f0ea10ac562c1538dee681f1727151e6` |
| `SenderFrozen(address,address)` | `sender`, `actor` | `0xbcc778b1735935d8f1de4988aa99c5a443739e2fb826dc7aa3f3bf64bb115fb8` |
| `SenderUnfrozen(address)` | `sender` | `0xf70670b858d56ee8e00bdc112191de0411959259f47dcbc6977aace0aee11765` |
| `SpendRecorded(address,address,address,uint256,bytes4)` | `sender`, `asset`, `target` | `0xc8e3d7812ff5ee9233152255de3b82224861baad07a1550a51ccd7174f1e7f88` |
| `GuardianUpdated(address,address)` | `oldGuardian`, `newGuardian` | `0x064d28d3d3071c5cbc271a261c10c2f0f0d9e319390397101aa0eb23c6bad909` |
| `ConsumerAuthorizationSet(address,bool)` | `consumer` | `0x5f7c8bcc9fe1f59809d268c8cf6b63a36c4aedb54e3a40628113344d5620dd45` |

## Consumer requirements

| Consumer | Required reads and writes |
|---|---|
| SuperPaymaster or account validation | Call `checkPolicy`. After execution, an authorized consumer calls `recordSpend`. |
| SDK policy display | Read `getAssetPolicy`, `getTargetScope`, `getTargetVelocity`, `isSelectorAllowed`, `getAssetSpend`, and `isFrozen`. Decode `getAssetSpend.spentInWindow` as `uint256`. Read pending operations from the external `TimelockController`, not PolicyRegistry. |
| DVT policy service | Read `getAssetPolicy`, `getTargetScope`, and `getTargetVelocity` together. Also read selector permissions, frozen state, and `getAssetSpend` with a `uint256 spentInWindow`. Index the scope, velocity, selector, freeze, and spend events. |
| Slash-policy reader | Use the same `checkPolicy` schema and `getAssetSpend` counter type as validation and DVT nodes. |

Reading `getTargetScope` without `getTargetVelocity` is incomplete when `velocityWindow != 0`.
The scope supplies the window, while the velocity getter supplies the asset-specific limit and its
`configured` flag.

## ABI migration from PolicyRegistry 1.0.0

PolicyRegistry 3.0.1 is a new deployment target, not an in-place upgrade.

| Change | Migration requirement |
|---|---|
| `getAssetSpend(address,address)` keeps selector `0x715904dd`, but `spentInWindow` changed from `uint128` to `uint256`. | Update strict ABI decoders even though the selector did not change. |
| `getContractScope(address,address)` was replaced by `getTargetScope(address,address)`. | Replace selector `0x35cefaa8` with `0x7ac0774b` and decode `(bool,bool,uint64,bool)`. |
| The target velocity limit moved out of `ContractScope`. | Call `getTargetVelocity(address,address,address)` with selector `0xcb9fa794`. |
| `setContractScope` and `tightenContractScope` lost the `uint128 velocityLimit` tuple field. | Use selectors `0xc28b58c1` and `0x7f6f42f0`, then call the separate target-velocity setter when needed. |

The old `getContractScope` selector `0x35cefaa8`, old `setContractScope` selector `0x3ef43aff`, and
old `tightenContractScope` selector `0xccd7129f` are not implemented by 3.0.1 and revert.
