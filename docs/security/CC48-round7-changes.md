# CC-48 round-7 — the gate now enforces the property it was printing

> Scope: `fcc205ee` → this commit. The independent reviewer of `fcc205ee` confirmed
> round-6's BLOCKER-1 closed **against the real chain**, and accepted MEDIUM-1
> (exact-width probe), HIGH-1's *argument* half, and all four round-6 LOWs. What follows is
> the half of HIGH-1 that was not delivered, one MEDIUM that was closed only halfway, one
> MEDIUM of missing operational truth, five LOWs, and the Registry-governance items from
> the archived original checklist.
>
> **Supersedes:** §3 of [`CC48-round6-changes.md`](./CC48-round6-changes.md) (the gate's
> criterion and every "must be a Safe multisig" phrasing), and adds a prerequisites block
> to its §1 conclusion. Those sections are annotated in place rather than deleted — the
> *wrong* claim is the interesting part of the record.

| Finding | Severity | Status |
|---|---|---|
| HIGH-1 — the gate checked `code.length > 0` while claiming to enforce a Safe multisig; a 7702-delegated EOA and a 1-of-1 forwarder both passed | HIGH | fixed |
| MEDIUM-1 — the catch-all sentinel was sent as a bare 4-byte selector, so an arg-checking fallback evaded it and forged `Present` + zero pending | MEDIUM | fixed |
| MEDIUM-2 — "the real 4.3.0 predecessor is unblocked" is true of the probe and false of the operation: both live Sepolia owners are EOAs | MEDIUM | fixed (documented; no false claim remains) |
| LOW-1 — the absence argument was written as a statement about arbitrary contracts | LOW | fixed |
| LOW-2 — the ABI generator was fail-open when a build artifact was missing | LOW | fixed |
| LOW-3 — `queueGuardianSlash`'s `verifier.code.length == 0` has the same 7702 blind spot | LOW | fixed |
| LOW-4 — `chainid == 31337` was an unconditional gate bypass, and a mainnet fork reports 31337 | LOW | fixed |
| LOW-5 — no Safe-side onboarding path, so the cheapest field fix was to point `GOVERNANCE_OWNER` at a self-controlled contract | LOW | fixed (runbook) |
| checklist — `setCreditPolicy` is immediate `onlyOwner`; the atomic batch had no execution test | — | fixed |

---

## 1. HIGH-1 — `code.length > 0` is not a multisig, and at Pectra it is not even a contract

### What round 6 shipped versus what round 6 said

`GovernanceOwnerGate` checked exactly one thing:

```solidity
if (ownerAddr.code.length > 0) {
    console.log("  [gov-gate] ... owner is a contract (Safe/Timelock):", ownerAddr);
    return;
}
```

while the revert string said *"owner must be a Safe multisig on a production chain"*, the
NatSpec said *"the thing carrying the residual risk is the owner being a multisig, and
NOTHING ELSE"*, `BLSAggregator`'s disarm NatSpec said *"the multisig is the ONLY governance
defence"*, and §3 of the round-6 document said the same. A downstream consumer (DVT, ops)
reading any of those four sites would have taken "multisig enforced" into their threat
model. Two shapes that are **one private key** passed the gate:

| Shape | `code.length` | Passed round-6 gate | Reality |
|---|---|---|---|
| EIP-7702 delegated EOA | 23 (`0xef0100 ‖ address`) | yes, and logged as *"owner is a contract (Safe/Timelock)"* | the private key still signs everything |
| 1-of-1 forwarder | > 0 | yes | one hot key behind a contract address |

The 7702 case is the ordinary case, not the exotic one: Sepolia and Ethereum mainnet are
both past Pectra, one self-signed `SET_CODE` transaction gives any EOA that code, and
mainstream "smart EOA" wallets delegate by default. An operator using a new wallet would
have been waved through silently. What the owner holds on that path is
`emergencyDisarmFraudProofVerifier()` — immediate, unannounced, repeatable — i.e. the power
to front-run every future `queueGuardianSlash` out of the mempool.

### What the gate enforces now

`requireGovernanceOwner` / `requireGovernanceOwnerStrict` classify the owner first
(`ownerKind`: `Eoa` / `Delegated7702` / `Contract`) and then, for `Contract`, read a
**Safe-compatible M-of-N configuration** with an exact, fail-closed decode:

| Check | Refusal reason |
|---|---|
| code present | EOA path |
| code is **not** `0xef0100 ‖ address` (23 bytes) | named as a 7702 delegation, not silently accepted |
| `getThreshold()` answers **exactly 32 bytes** | revert, empty returndata and wide proxy answers are all refusals |
| `threshold >= 2` | `threshold < 2 (a 1-of-N owner is one key)` |
| `getOwners()` is a **canonical** `address[]` — head offset `0x20`, `length` matching the returndata to the byte, every word with clean upper 96 bits, non-zero, **distinct**, `<= 64` entries | one message naming `getOwners()` |
| `owners.length >= threshold` | `owners.length < threshold (unsatisfiable)` |
| `GOVERNANCE_OWNER` unset vs. set-but-not-applied | two **different** messages: "NOT SET" and "is set, but the owner above is not it" |

**What this does NOT prove, stated in the code, in the log line and here:** it does not
prove the owner is a **canonical Gnosis Safe**. A contract can implement both methods and
return whatever it likes while a single key still controls execution. Proving canonicity
needs an audited runtime-codehash or proxy-factory allowlist per chain, which this repo
does not have. Every message, log line and document therefore says
**"Safe-compatible M-of-N"** and never "is a Safe" — and there is a test asserting that no
refusal string contains the old phrasing.

Accepted deployments now emit the evidence the reviewer asked for:

```
[gov-gate] BLSAggregator owner is Safe-compatible M-of-N: 0x…
[gov-gate]   getThreshold()     : 2
[gov-gate]   getOwners().length : 3
[gov-gate]   criterion          : code, not 0xef0100, threshold>=2, owners>=threshold, distinct
[gov-gate]   NOT proven         : that this is a canonical Gnosis Safe (no
[gov-gate]                        runtime-codehash / factory allowlist exists yet)
[gov-gate]   owner: 0x…
```

### Registry may be Timelock-owned; the aggregator may not

The two questions were conflated by "owner must be a contract". They are now separate:

- **`BLSAggregator`** requires Safe-compatible M-of-N. A `TimelockController` is
  **refused** — it has no `getThreshold()`, and more to the point a timelocked emergency
  stop is not an emergency stop.
- **`Registry`** may be owned by either. `UpgradeRegistryTo570` makes the operator say
  which: set `TIMELOCK` and it asserts `Registry.owner() == TIMELOCK` **and**
  `TIMELOCK.getMinDelay() > 0` (`requireTimelockOwner`); leave it unset and Registry is
  held to the same M-of-N bar. Printing `scheduleBatch` calldata proves neither.

| Property | Test |
|---|---|
| a 7702-delegated EOA is refused on production **and** by the migration gate on a testnet | `test_GateBehaviourAcrossChainsAndOwnerShapes` |
| 23 bytes without the prefix is ordinary code (prefix **and** length, not length alone) | `test_OwnerKindClassifiesDelegationDesignatorsExactly` |
| a 1-of-1 forwarder is refused, and the reason names the threshold | `test_GateBehaviourAcrossChainsAndOwnerShapes`, `test_ThresholdBoundaries` |
| a contract with no M-of-N surface is refused | `test_GateBehaviourAcrossChainsAndOwnerShapes` |
| 11 malformed/hostile answers (revert, empty, wide, non-canonical offset, length mismatch, dirty word, duplicates, zero owner, empty set, oversize set) are all refused | `test_MalformedAnswersAreAllRefused` |
| a real 2-of-3 passes, and `readMofN` reports the threshold/count that gets logged | `test_GateBehaviourAcrossChainsAndOwnerShapes`, `test_ReadMofNReportsTheConfigurationItAccepted` |
| N-of-N passes; N+1-of-N is refused | `test_ThresholdBoundaries` |
| no refusal string claims canonicity | `test_GateBehaviourAcrossChainsAndOwnerShapes` |
| `TIMELOCK` gate asserts ownership **and** a non-zero delay, against a real `TimelockController` | `test_TimelockGateAssertsBothOwnershipAndANonZeroDelay`, `test_GateAssertsOwnershipAndANonZeroMinDelay` |

> **Harness note.** The gate reads process environment variables and `forge` runs a
> contract's test functions **in parallel**, so `vm.setEnv` is a shared mutable global
> across those threads. Split across several test functions these cases failed in a
> different combination on every run (observed: two consecutive runs, two different failure
> sets). Every env-dependent case is therefore one test function,
> `test_GateBehaviourAcrossChainsAndOwnerShapes`, with each section restating the full
> environment. Three consecutive runs, 6/6 each.

---

## 2. MEDIUM-1 — a catch-all detector that is itself detectable

Round 6 probed `CATCH_ALL_SENTINEL` **first**, before any real getter — correct design. But
it sent a **bare 4-byte selector** while every real getter probe was sent with full
arguments. One instruction tells the two apart:

```solidity
fallback() external {
    assembly {
        if lt(calldatasize(), 36) { revert(0, 0) }   // <- evades a selector-only sentinel
        mstore(0x00, 0)
        return(0x00, 0x20)                            // <- forges a clean 32-byte answer
    }
}
```

Under round 6 that contract reverted on the sentinel ("not a catch-all"), answered
`pendingGuardianSlashCount(address)` with a clean word (`Present`), and
`requireNoPendingCases` then read its fabricated `0` as "no pending case" — for a contract
that was never actually asked anything. That is precisely the fail-open step 0 exists to
close, reopened by the shape of the probe.

**Fix:** the sentinel is sent with the argument list its own pre-image declares —
`abi.encodeWithSelector(CATCH_ALL_SENTINEL, bytes32(0), uint256(0))` — so it is
indistinguishable from a genuine call to a real method.

`test_AnArgStrictCatchAllCannotForgePresentOrZeroPending` asserts the **defect first**
(the fixture really does fabricate a clean zero word, and really does evade the round-6
probe shape, reproduced inline so a regression re-fails this test) and only then the fix
(`Ambiguous`, and `requireNoPendingCases` reverts).

---

## 3. MEDIUM-2 — "unblocked" is true of the probe and false of the operation

Round 6's §1 concluded that the real 4.3.0 predecessor is now scannable. That is correct at
the capability-probe level and was re-verified against chain by the reviewer. It is **not**
true of running `UpgradeRegistryTo570` against the live Sepolia stack today, and the reason
changed rather than disappeared.

Verified read-only against `ethereum-sepolia-rpc.publicnode.com` while writing this section
(`cast call` / `cast code` only — no transaction was sent):

| Contract | Address | `owner()` | owner code |
|---|---|---|---|
| Registry (`Registry-5.4.2`) | `0xf5Bf37ca…8E71` | `0xb5600060e6de5E11D3636731964218E53caadf0E` | `0x` — **EOA** |
| BLSAggregator (`BLSAggregator-4.3.0`) | `0x174b60bB…0158` | the same EOA | `0x` — **EOA** |

So the script stops at `requireGovernanceOwnerStrict(proxy, owner, "Registry")` and never
reaches the capability probe. This is **not a round-7 regression** — Registry's owner has
had to be a contract since round 3 — but the round-6 commit title
("unblock the real 4.3.0 predecessor") and §1's conclusion did not say it.

**Prerequisites for a real migration, now written down (see also the runbook):**

1. `Registry.owner()` → Safe-compatible M-of-N **or** a `TimelockController` with
   `getMinDelay() > 0`. **There is no script in this repository that does this** —
   `DeployBLSAggregatorSepolia` can produce a Safe-owned *aggregator* via
   `GOVERNANCE_OWNER`, but the Registry side is a **manual ops step**
   (`Registry.transferOwnership(<safe|timelock>)` from the current owner).
2. `NEW_BLS_AGGREGATOR.owner()` → Safe-compatible M-of-N (a Timelock will be refused here).
3. An EIP-2537 (Prague) RPC, so the weak-key scan cannot report "clean" because it could
   not run.
4. `OLD_BLS_AGGREGATOR` == `Registry.blsAggregator()` exactly (round-5 HIGH-1).

**No end-to-end migration of the live Sepolia stack is claimed.** RepCredit successor
evidence remains a **fresh isolated deployment**; the old experiment stack is not upgraded
in place (that decision is recorded in CC-48 comment `75a935c7`).

---

## 4. LOW-1 — the absence argument had been written one scope too wide

The NatSpec said a build with none of the four case-machine getters "contains no
`queueGuardianSlash`, hence no case store". True of **this repository's build lineage**;
false as a statement about arbitrary contracts. A contract with a real case store and a
real `queueGuardianSlash` whose counters are `private` classifies `Absent` too, and for it
the printed "it cannot hold a case" is simply a false statement.

No exploitable path — `requireDeclaredPredecessor` binds the scanned address to
`Registry.blsAggregator()`, so it is not a free parameter — so this is a wording fix, in
both the NatSpec and the **log line** an operator actually reads:

```
pending-case check SKIPPED: no build of THIS aggregator with
none of the four case-machine getters can create a case, and the
predecessor is bound to Registry.blsAggregator() above.
```

---

## 5. LOW-2 — the ABI generator was fail-open exactly where it matters most

`scripts/extract_v3_abis.sh` printed `❌ Warning: Could not find build artifact…` and
**carried on**: the manifest was recomputed over whatever happened to be in `abis/`, and the
script exited **0**. The reviewer hit this on the first reproduction of round-6's ABI
evidence — `out` was a symlink, `find` did not follow it, every artifact was missing — and
got a green run over a stale manifest. That is the same defect round-6's LOW-4 fix removed
from the JSON validation ("silently did nothing" must not be indistinguishable from
"passed"), and a missing artifact is far more common than a missing `jq`.

Failures are now **accumulated** (one run names every missing contract rather than stopping
at the first), the manifest is not regenerated over them, and the script exits **1**. The
symlink cause is named in the failure text, because that is the form it takes in practice.

**The fix immediately found a real one.** With fail-closed in place, the very first clean
run failed:

```
❌ 1 of 18 ABI artifacts could not be found:
   - BLSValidator
```

The standalone `BLSValidator` contract was **deleted long ago** — see
`contracts/script/checks/Check08_Wiring.s.sol:73`, *"standalone BLSValidator was deleted;
only the aggregator is wired now"* — there is no `contracts/src/**/BLSValidator.sol` and no
`abis/BLSValidator.json`. Every regeneration since that deletion printed a warning and
**exited 0**, so the stale entry survived every ABI sync to `repo:sdk`. That is the
argument for the change, demonstrated rather than asserted: "silently did nothing" was
indistinguishable from "passed" for however many releases. The entry is removed, with the
reason recorded at the removal site.

Reproduction of the failure mode itself (artifact hidden, then restored):

```
$ mv out/BLSAggregator.sol/BLSAggregator.json{,.hidden}
$ bash scripts/extract_v3_abis.sh ; echo $?
... ❌ 1 of 18 ABI artifacts could not be found ...
1
```

---

## 6. LOW-3 — the same 7702 blind spot inside the contract

`queueGuardianSlash` checked `verifier.code.length == 0`. A 7702-delegated EOA satisfies
`code.length != 0` and its delegate can return `true` unconditionally — and because round 4
**freezes the verdict** into the case, that fabricated `true` then survives rotation,
disarm, expiry and retry. A hot key authoring a frozen verdict is strictly worse than the
plain-EOA case round 3 closed.

`queueGuardianSlash` now also rejects the delegation designator
(`VerifierIsDelegatedEoa`). The check is prefix **and** length (`extcodesize == 23` plus a
3-byte `EXTCODECOPY`), so a genuine 23-byte contract is unaffected; `0xef` is a reserved
initial byte (EIP-3541), so no deployable runtime can produce a false positive. Cost: one
`EXTCODESIZE` + one `EXTCODECOPY` of 3 bytes, regardless of target size.

`test_QueueRejectsA7702DelegatedEoaVerifier` asserts the fixture **passes** the old
`code.length` test before asserting the new revert; `test_A23ByteContractIsNotMistakenForA
7702Delegation` is the converse.

---

## 7. LOW-4 — `chainid == 31337` was an unconditional bypass

`anvil --fork-url <mainnet>` reports **31337**. Round 6 skipped both gates there
unconditionally, so a fork rehearsal of a production chain "passed" a gate that had never
executed — false assurance in exactly the rehearsal that exists to produce assurance.
Nothing on-chain distinguishes a fork from a fresh local node, so the distinction is made by
a human: `LOCAL_DEV_GOVERNANCE_ACK=true`, and the skip is **printed** so a transcript shows
the gate was skipped rather than satisfied. Both anvil entry points (`./deploy-core anvil` and
`scripts/deploy-core.sh anvil`) set it — a genuinely local node started by this repo's own
tooling; no other environment sets it, and `run_full_regression.sh` reaches anvil only
through `./deploy-core`.

Demonstrated end to end against a live anvil node:

```
# without the ack
Error: script failed: CC-48 round-7 LOW-4: chainid 31337 skips the governance gate for
BLSAggregator, so it must be acknowledged with LOCAL_DEV_GOVERNANCE_ACK=true. Note that
`anvil --fork-url <mainnet>` ALSO reports 31337: ...

# with it
[gov-gate] SKIPPED on local chain 31337 for BLSAggregator 0xf39Fd6e5…92266
[gov-gate] acknowledged via LOCAL_DEV_GOVERNANCE_ACK. Nothing about the
[gov-gate] owner was verified. If this was an --fork-url rehearsal, it
[gov-gate] rehearsed a system with no governance gate.
ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

---

## 8. LOW-5 — the bring-up tension that pushed operators toward the hole

With `GOVERNANCE_OWNER` enforced, `registerBLSPublicKey`'s owner path and
`setPermissionlessBLSRegistration` must be driven from the Safe, and nothing in the repo
described how. The cheapest field fix was to point `GOVERNANCE_OWNER` at a self-controlled
contract — which round-6's gate accepted. The M-of-N check removes the easy version of that
shortcut; [`CC48-safe-onboarding-runbook.md`](./CC48-safe-onboarding-runbook.md) removes the
reason to look for one.

---

## 9. Archived original checklist — Registry governance and the atomic batch

From CC-48 comment `74c3e8c7`:

**`setCreditPolicy` is immediate `onlyOwner`, and the aggregator's Safe gate does not cover
Registry.** Addressed in §1: the migration script now requires the operator to declare
whether Registry is Safe-owned or Timelock-owned, and asserts the corresponding property.

**"prove the upgrade + baseline/caps batch has no intermediate executable window."**
`CC48RegistryTimelockGovernance.t.sol` runs a **real** OpenZeppelin v5.0.2
`TimelockController` owning a **real** `ERC1967Proxy` Registry, with the script's own salt
(`bytes32(uint256(0x5600))`) and predecessor (`bytes32(0)`) — so the test binds to the
shipped parameters, not to a convenient reimplementation:

| Property | How it is shown |
|---|---|
| the pre-batch state is the real one | `setCreditPolicy(0,0,0,true)` models an upgraded proxy whose new slots were never written by `initialize` (no hard-coded storage slot index) |
| only the proposer may schedule | a stranger's `scheduleBatch` reverts |
| the delay is real | `executeBatch` before `MIN_DELAY` reverts; `isOperationPending && !isOperationReady` |
| **no intermediate window** | the upgrade-only sub-batch hashes to a **different** operation id which `isOperation()` reports as never scheduled, and executing it reverts. There is no ordering an executor can choose that produces the intermediate state. |
| all three effects land together | after one `executeBatch`: `Registry-5.7.0`, aggregator wired, `maxTotalCreditExposure == totalCap`, `totalCreditExposure == baseline`, per-proposal cap set, owner unchanged |
| no replay | a second `executeBatch` reverts |
| the counterfactual is measured, not asserted | scheduling+executing the upgrade **alone** leaves `maxTotalCreditExposure == 0` and the aggregator unwired — the governance halt the batch exists to avoid |

**Release residuals, carried forward unchanged and NOT claimed as fixed:**

- **bytecode headroom.** `Registry` is the tightest of the three; measure before any core
  extension and split into modules rather than shaving. Current measurements are in §11.
- **watcher liveness.** Fraud detection still depends on an off-chain watcher noticing and
  queueing in time. There is no on-chain automatic detection, and this round does not claim
  one. It remains a paper/operating assumption.
- **proposal aggregate uplift** is bounded by `maxTotalCreditExposure` (protocol-wide
  stock), not by a per-proposal cap alone, so proposal splitting does not multiply the
  bound. Shipping version is the `Registry-5.7.0` candidate.

---

## 10. ABI / version impact

`BLSAggregator` gains one error and one rejection on a live path, so it is **not** a
comment-only round:

| Item | Before | After |
|---|---|---|
| `BLSAggregator.version()` | `BLSAggregator-4.9.0` | **`BLSAggregator-4.10.0`** |
| ABI | — | `+ error VerifierIsDelegatedEoa(address)` |
| `queueGuardianSlash` | rejects `code.length == 0` | also rejects `0xef0100 ‖ address` |
| domain separator | `keccak256(DOMAIN_NAME, chainid, aggregator, registry)` | **unchanged** — it does not commit to the version string |

`Registry`, `SuperPaymaster`, storage layouts and every other `version()` are unchanged.
Downstream (`repo:dvt`, `repo:sdk`) must re-sync `abis/BLSAggregator.json` and the version
pin; the verifier seam (`verify` selector `0x61077735`) and `assertSetBound`/
`assertDomainBound` signatures are unchanged.

---

## 11. Verification

Recorded in the CC-48 round-7 delivery comment: full Cancun and Prague runs, the focused
CC-48 suites, both build profiles, storage-layout and EIP-170 size checks, ABI
regeneration/reproducibility, and a `DeployAnvil` dry run with the explicit local
acknowledgement.
