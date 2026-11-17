# Step 4 (DVTValidator-0.9.0) rehearsal on an OP mainnet fork — head f2e86321

**Result: PASS.** DeployLive runs on the step-4 code, and the reputation branch works with real BLS keys under the 0.9.0 shape rules.

## Setup
- **Endpoint:** OP mainnet via Alchemy, forked with anvil at block **159657338**, chainId 10. This is the same fork block as the 1845b124 rehearsal.
- **Keys:** the deployer and ANNI are anvil test accounts. The governance owner, governor and guardian are all the Mycelium Safe `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`.
- **Guardians:** three anvil accounts with fresh random BLS scalars, generated for this run and not stored in the repo.
- **Deviation:** the Safe is impersonated on the fork.

## DeployLive (`deploylive.log`, `config.json`, `broadcast.json`)
- rc=0; `_assertWiring` passed, including the new `dvt.categoryCount() == 0` readback.
- **Versions:** BLSAggregator-4.14.1, DVTValidator-0.9.0, SuperPaymaster-5.5.2.
- **Post-deploy check** (`postdeploy.txt`, same `postdeploy_check.py` as before): 37 PASS / 16 FAIL. The PASS/FAIL set is **identical** to the 1845b124 rehearsal. The 16 FAIL are the deployer-held privileges that L6–L10 hands over.

## Reputation branch (`rep-branch.log`, `rep-broadcast.json`, `rep-readback.txt`)
- **Flow:** stake → `addValidator` → `registerBLSPublicKey` (real PoP) → thresholds 2/2 → `createProposal(0, 0, …, 0)` → `executeWithProof(1, [target], [50], 1, "" /* evidence */, 2-of-3)`.
- **Transactions:** 19, receipts 19/19 status 1.
- **Readback:** `globalReputation(target)=50`, `agg.executedProposals(1)=true`, thresholds 2/2, `categoryCount=0`.

## Controls (eth_call, live 0.9.0 deployment)

| # | Case | Result |
|---|---|---|
| PC | fresh 2-of-3 proof, proposal 2, empty evidence | **accepted** (`0x`) |
| R2 | reputation create with nonzero evidenceHash | `ReputationEvidenceHashNotZero()` |
| R3 | the PC's valid proof with non-empty evidence | `ReputationEvidenceNotEmpty()` |
| S1 | slash-shape create on the live empty allowlist | `UnknownEvidenceCategory(bytes32)` |
| M1 | reputation proposal executed with an empty batch | `ProposalShapeMismatch()` |
| N1 | replay of the executed proof on proposal 1 | `ProposalExecutedAlready()` |
| N2 | proposal-1 proof applied to proposal 2 | `SignatureVerificationFailed()` |
| N3 | score changed to 150 | `SignatureVerificationFailed()` |
| N5 | non-validator caller | `NotAuthorizedExecutor()` |
| N6 | 1-of-3 proof | `InvalidSignatureCount(uint256,uint256)` |

## Mutations (`mut.tsv`, `mutation-results-final.txt`)
Each of the ten (A)-rule checks was removed in turn. Every one of the ten mutations turned its own targeted test red.
