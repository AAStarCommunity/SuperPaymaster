# CC-89 stage-2 — over-issue guardian-collusion slash: Sepolia E2E runbook

Re-runnable record of the SP↔DVT testnet E2E that proved the RepCredit paper's
`ρ·S_op` term (a colluding DVT guardian loses its ROLE_DVT stake). Passed on
Sepolia 2026-08-15.

## What it proves

A guardian proposal that falsely accuses a token of over-issuance (the token's
`isOverIssued()` is `false`) is co-signed by ≥3 guardians, landed via
`verifyAndExecute` (which snapshots the signer address set as the A' commitment),
then caught by DVT's over-issue fraud-proof verifier — slashing every guilty
guardian's full ROLE_DVT stake to 0 and auto-ejecting them from the signer set.

## Scripts in this directory

| File | Role |
|---|---|
| `DeployBLSAggregatorSepolia.s.sol` | Deploy a dedicated E2E `BLSAggregator` 4.3.0 (A') pointing at the live registry/superPaymaster/dvtValidator + authorize it as a GTokenStaking slasher. |
| `E2EGuardianSetupSepolia.s.sol` | Register 3 BLS keys (owner path) + fund & ROLE_DVT-stake the 2 throwaway slot2/3 addresses. **Needs `--evm-version prague`** (EIP-2537 BLS precompiles). |
| `MockUnderCapXPNTs.sol` | Stand-in disputed token whose `isOverIssued()` is `false` (and recompute getters read healthy). |
| `MockDVTAccept.sol` | No-op `DVTValidator` stand-in so `verifyAndExecute` can mark the ad-hoc proposalId executed without a pre-existing DVTValidator proposal. |

`.env.e2e-guardians` (gitignored) holds the throwaway slot2/3 private keys and the
3 guardian BLS pubkeys/PoP supplied by DVT. Regenerate per run — see step 2.

## Prerequisites

- `.env.sepolia` with `SEPOLIA_RPC_URL` + `PRIVATE_KEY_JASON` (== aggregator owner == Registry owner).
- DVT delivers, per run: 3 guardian `{pubkey (G1 128B), PoP (G2 256B), slot}`, an
  over-issue fraud-proof verifier deploy, and a running signing pipeline
  (`cc89-cosign` 3-of-3 aggregate signature) — coordinated via CC-89.

## Runbook (each command from repo root, env sourced)

1. **Deploy the E2E aggregator** (SP):
   ```
   forge script contracts/script/v3/DeployBLSAggregatorSepolia.s.sol:DeployBLSAggregatorSepolia \
     --rpc-url $SEPOLIA_RPC_URL --broadcast
   ```
   Give the address to DVT → DVT deploys `OverIssueFraudProofVerifier(aggregator)`.

2. **Provision guardians** — write slot2/3 keys + DVT's 3 pubkeys/PoP into
   `.env.e2e-guardians`, then (note the REQUIRED prague override):
   ```
   forge script contracts/script/v3/E2EGuardianSetupSepolia.s.sol:E2EGuardianSetupSepolia \
     --rpc-url $SEPOLIA_RPC_URL --evm-version prague --broadcast
   ```
   slot1 == jason is already ROLE_DVT-staked; only its BLS key is registered.

3. **Arm** (SP): `setFraudProofVerifier(<DVT verifier>)` on the aggregator.

4. **Wiring fix (temporary, shared Registry)** — `verifyAndExecute`'s slash-only
   path calls `Registry.markProposalExecuted` (gated on `Registry.blsAggregator`)
   and `DVT_VALIDATOR.markProposalExecuted`. For a dedicated E2E aggregator:
   - `Registry.setBLSAggregator(<E2E aggregator>)` — **restore to the old
     aggregator after the run.**
   - Deploy `MockDVTAccept`, `aggregator.setDVTValidator(<mock>)` (the setter
     rejects `address(0)`, so a no-op mock is used instead of unsetting).

5. **Disputed proposal** (DVT signs, SP submits) — fields:
   `proposalId` (fresh, nonzero), `operator = address(0)` (skip operator slash;
   must equal the `op` inside `evidenceHash`), `slashLevel = 1` (MINOR → threshold
   3 → mask `0x7`), `repUsers = []`, `newScores = []`, `epoch`, `disputedToken`
   with `isOverIssued() == false`,
   `evidenceHash = keccak256(abi.encode("DVT_OVERISSUE_EVIDENCE_V1", token, operator, epoch))`.
   DVT's `cc89-cosign` returns `proof = abi.encode(uint256 signerMask=0x7, bytes sigG2)`.
   Cross-check `evidenceHash`/`expectedMessageHash` on both sides before submitting.

6. **Submit** (SP, owner): static-call first on the live node (real BLS
   precompiles) to catch reverts, then send:
   ```
   verifyAndExecute(proposalId, operator, slashLevel, [], [], epoch, evidenceHash, proof)
   ```
   Stores `proposalSignersCommitment[proposalId]` (A' snapshot).

7. **Slash** (DVT): watcher resolves `claimedSigners` at the execution block,
   assembler builds the fraud proof, then `executeGuardianSlash(fraudProofId,
   guiltyGuardians, fraudProof)` — permissionless. Guilty guardians' ROLE_DVT
   locks go to 0 → auto-eject (a later `verify(mask=0x7)` reverts
   `SlotValidatorStakeBelowMinimum`).

8. **Cleanup** (SP): restore `Registry.setBLSAggregator(<old aggregator>)` and
   `staking.setAuthorizedSlasher(<E2E aggregator>, false)`.

## 2026-08-15 run — on-chain artifacts (Sepolia)

- aggregator (A' 4.3.0): `0xf44E7E51EFFa867114BE48fA92411fE216b1A285`
- verifier (DVT): `0xd7111fcC31B52dC451f2B7400Cd75B434E2b1abd`
- disputed token (isOverIssued=false): `0x8dE1b6585Bdf5a3e6F13B3125B2d40CC34fc005b`
- `verifyAndExecute`: `0x2984a02c3396b21a55e0a5336d1f7099cd7ae2758b257279447841f9c814a030` (block 11491912)
- `executeGuardianSlash`: `0xb870688e6c156e4e7f97cbad390e72e5900fc3384da0809d042fa023307991ba` (block 11491914)
- result: 3 guardians' ROLE_DVT locked stake 30e18 → 0, auto-ejected.

Note: that run really slashed the 3 test guardians to 0 (ejected). A re-run needs
fresh stakes + re-registration (regenerate `.env.e2e-guardians`).
