# REG-02 — Sepolia live Registry: state unreachable by 5.10.0 reconcile flags?

Read-only. Chain 11155111. Reads pinned at / scanned to block **12098756** (head on both endpoints at run time).
Exact commands: `commands.sh` (+ `fetch_logs.sh`, `state_reads.py`). Raw logs: `logs/`. Per-user state: `state_a.json`, `state_b.json`.

## Verdict
- **(A) count = 0.** No `SBTBurnFailed` was ever emitted by the Registry proxy. Independently, by state: of 27 SBT holders, 0 have `userRoleCount == 0`.
- **(B) count = 0.** No `RoleExited` (any roleId, any signature variant) was ever emitted by the Registry proxy. All 3 addresses that ever registered ENDUSER still hold it.
- So no exit-path residue exists for the 5.10.0 reconcile functions to miss.

## Correction to the premise
- The live proxy reports **`Registry-5.8.0`**, not 5.9.0 (both endpoints). EIP-1967 impl slot = `0x9bed0f58…cceE`, which matches `registryImpl` in `deployments/config.sepolia.json`. origin/main source says `Registry-5.9.0`, so the in-place upgrade on Sepolia goes **5.8.0 → 5.10.0**. Event signatures are the same in 5.8.0 and main.
- `ROLE_ENDUSER()` has no getter (the call reverts, because the ROLE_* values are file-level constants in `IRegistry.sol`). Value used: `keccak256("ENDUSER")`.

## Addresses / deployment
| | address | first block with code (binary search on `codesize -B`) | notes |
|---|---|---|---|
| Registry proxy | 0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71 | 11151002 (codesize 0 at 11151001) | 6 `Upgraded` events: bf7c92fe@11151002, 60a5c660@11151211, 60a5c660@11151220, 6af5a2a7@11228198, 9e5da7b4@11228783, 9bed0f58@11599363 |
| MySBT | 0x4867B4302bf4C7818b71F55E53A3520Ee1855Aa7 | 11151006 (codesize 0 at 11151005) | `MySBT-3.2.0`, codesize 12111, immutable `REGISTRY()` = the proxy above. It was deployed after the proxy, so every SBT was created through this Registry |

## Scan
- Ranges: Registry 11151002–12098756, MySBT 11151006–12098756, in 100k-block pages. **No page errored on either endpoint and there are no gaps** (see `run_*.txt`).
- Primary evidence is an **unfiltered** `eth_getLogs` by address, so it catches any signature variant. Registry has 85 logs (first 11151002, last 11652245). Every topic0 decodes against `abis/*.json` to one of: RoleRegistered 36, RoleGranted(bytes32,address,address) 15, CreditTierUpdated 8, Upgraded 6, BLSAggregatorUpdated 6, ReputationSourceUpdated 4, ProposalMarkedExecuted 3, and 1 each of OwnershipTransferred, Initialized, StakingContractUpdated, MySBTContractUpdated, SuperPaymasterUpdated, CreditPolicyUpdated, CreditExposureResynced. RoleExited, SBTBurnFailed, RoleRevoked and SBTStatusSyncFailed all count 0.
- Variants checked from git history: `RoleExited(bytes32,address,uint256,uint256)` (0x0d936141…), legacy `RoleExited(address,bytes32,uint256,uint256,uint256,uint256)` (Registry_v3_0_0), `SBTBurnFailed(address,bytes32)` (0xf6da96ea…), `RoleGranted(bytes32,address,uint256)` (legacy). The unfiltered histogram shows none of the exit variants.
- MySBT has 54 logs: Transfer 27 + SBTMinted 27, all mints. There are 0 SBTBurned, 0 MembershipAdded and 0 MembershipDeactivated.

## Positive controls (same getLogs shape, same ranges, topic0-filtered)
| query | rpca (Alchemy) | rpcb (Tenderly) |
|---|---|---|
| RoleRegistered(bytes32,address,uint256,uint256) | 36 | 36 |
| RoleGranted(bytes32,address,address) | 15 | 15 |
| RoleExited(bytes32,address,uint256,uint256) | 0 | 0 |
| SBTBurnFailed(address,bytes32) | 0 | 0 |
| RoleGranted(bytes32,address,uint256) | 0 | 0 |
| unfiltered Registry / MySBT | 85 / 54 | 85 / 54 |

The full Registry and MySBT log sets (block, tx, logIndex, topics, data) are **byte-identical** across the two endpoints. Tenderly accepted 100k-block pages without splitting.

## State reads (block 12098756, both endpoints, `state_a.json == state_b.json`)
- Universe: every address in RoleRegistered, RoleGranted or MySBT Transfer-to. That is 27 addresses, and all 27 hold an SBT today.
- `userRoleCount` is `internal`, so it was read from storage slot `keccak(user . 16)`. Slot 16 comes from the `out/` storageLayout. The slot was validated by comparing it with the count of `hasRole()==true` over the 7 ROLE_* constants: 27/27 match. The distribution is {1: 22, 2: 3, 4: 2}, so no user has 0, and the validation is not a trivial 0 == 0.
- **(A) by state:** 0 users have SBT>0 and userRoleCount==0.
- **(B) by event:** RoleRegistered(ENDUSER) appears for 3 users: 0xecd9c07f…dd70, 0x179faf25…d31c, 0xb78ef5c8…a1ed. All 3 still have `hasRole(ENDUSER)=true`, each with 1 active membership in community 0xEcAACb91…33c9.

## Caveat for the 5.10.0 reconcile design (not part of (B) as defined)
A naive **state** predicate, `!hasRole(ENDUSER) && active membership`, matches **24** users today: 21 DVT-only holders plus COMMUNITY/PAYMASTER holders. In every case the single active membership's community is **the user's own address**, a self-membership created when a non-ENDUSER role was registered. None of these users ever held or exited ENDUSER. If any 5.10.0 reconcile path or permissionless sweep keys on that state predicate instead of an ENDUSER-exit flag, it would hit these 24 accounts. Full list: `state_a.json`, and `state_a_summary.txt` line "B-state".

## Not verified / limits
- Completeness of eth_getLogs cannot be proven from returned data. The supporting evidence is: two independent providers agree byte for byte, the positive controls are non-zero on both, and the state-based cross-check independently agrees for (A).
- For (B), the "never exited" conclusion rests on logs. The state cross-check only shows that all 3 historical ENDUSER registrants still hold ENDUSER. If some address held ENDUSER without any RoleRegistered or RoleGranted log, it would be outside the universe. That is **not verified**, but no code path doing so is known.
- Storage slot 16 for `userRoleCount` was taken from the main-branch build. It is validated empirically against 5.8.0 on-chain by the 27/27 hasRole match.
