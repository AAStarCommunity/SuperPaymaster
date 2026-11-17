# DeployLive execution rehearsal — main 1845b124 (2026-11-17)

**Result: `DeployLive.run()` completed (rc=0) on the OP mainnet fork, including `_assertWiring`. Post-deploy check: 37 of 53 PASS; the 16 FAIL are all privileges still held by the deployer.**

## Setup
- **Endpoint:** OP mainnet public endpoint (Optimism Foundation, no API key), forked with anvil, chainId 10.
- **Fork block:** 159657338.
- **Real contracts on the fork:** EntryPoint v0.7 (0x0000000071727De22E5E9d8BAf0edAc6f37da032), Chainlink ETH/USD (0x13e3Ee699D1909E989722E753853AE30b17e08c5), SimpleAccountFactory (0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985).
- **Governance:** GOVERNANCE_OWNER, GOVERNOR_ADDRESS and GUARDIAN_ADDRESS are all set to the Mycelium Safe 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 (2-of-3 on OP). This is a real Safe on the fork, so the production governance gate path runs.
- **Keys:** the deployer and ANNI are anvil test accounts 0 and 1.
- **Files:**
  - `deploylive.log` — run output; ends with "Script ran successfully. ONCHAIN EXECUTION COMPLETE & SUCCESSFUL."
  - `config.json` — deployed addresses.
  - `broadcast.json` — transaction list.
  - `postdeploy.txt` — post-deploy check output (run with `postdeploy_check.py`).

## Post-deploy check: 37 PASS / 16 FAIL (53 assertions)

FAIL — still held by the deployer. These are exactly the owner-table gaps L6–L10 must close; DeployLive needs the same handover.
- **owner():** SuperPaymaster, Registry, GTokenStaking, GToken, ReputationSystem.
- **Registry roleConfigs[id].owner:** all 7 roles.
- **Other roles:** SP.treasury, staking.treasury, MySBT.daoMultisig, BLSAggregator.slashPolicyAdmin.

PASS, including:
- **Reputation sources:** repSystem and the aggregator are sources; the deployer is not (#633).
- **Slashing:** authorizedSlashers(aggregator) == false; fraudProofVerifier == 0.
- **Aggregator isolation:** the aggregator owns no contract and holds no ETH, GToken, aPNTs or pNTs.
- **Timelock and validators:** the deployer holds no timelock role; DVT.isValidator(deployer) == false.
- **Ownership already moved to the Safe:** owners of BLSAggregator, DVTValidator, xPNTsFactoryV2, AOAProtocolRegistry, xPNTsFactory v1 and X402Facilitator.
- **Generic-path denylist:** batchUpdateGlobalReputation, slash and slashByDVT each revert with ForbiddenGenericSelector (0xbccd864e). Positive control: an allowed selector (updateOperatorBlacklist) reverts with something other than ForbiddenGenericSelector, so it got past the guard.

INFO
- **Versions:** BLSAggregator-4.14.1, DVTValidator-0.8.1, SuperPaymaster-5.5.2.
- **Thresholds:** min 3 / default 7. These are the constructor defaults, since DeployLive does not set them; the manifest path sets 2/2.
- **TimelockController** 0x5969409aAE959726F6f1f6d05397eE9b65D80E97:
  - minDelay 172800.
  - The Safe holds proposer, executor and canceller **and DEFAULT_ADMIN_ROLE**. Sepolia's TL48 has admin = self only, so this differs.
- **PolicyRegistry.timelock** is the new TimelockController.
- **Legacy owners still the deployer:** PaymasterFactory, PaymasterV4 impl, MicroPaymentChannel.
- **GOVERNOR_ADDRESS / GUARDIAN_ADDRESS** default to the deployer when unset (V54Bootstrap.sol:79-80). The OP deploy must set them.

## Not covered yet
- Reputation branch run once with real BLS keys on this system: guardian registration, stake, and a genuine proof.
- ERC-7562 / bundler path.

## Reputation branch with real BLS keys — main cdb59d06 (2026-11-17)

**Result: PASS.** Run on the same fork, on top of the DeployLive state above (anvil snapshot `0x0` taken first).

### Setup
- **Guardians:** three anvil test accounts (#2, #3, #4).
- **Keys:** fresh random BLS scalars, generated for this run only and kept outside the repo. They pass the weak-key scan (`BLSKeyScanLib.isWeakScalarKey`).
- **Governance:** the Mycelium Safe is the aggregator and DVT owner. It was impersonated on the fork (`anvil_impersonateAccount`), so its calls were not 2-of-3 Safe transactions. Every other call came from its real role holder.
- **Order:**
  1. ROLE_DVT stake (minStake + ticket).
  2. `dvt.addValidator`.
  3. `dvt.registerBLSPublicKey` with a real PoP.
  4. Thresholds set to `setMinThreshold(2)` / `setDefaultThreshold(2)`. This is the manifest A10 → A11 order.
- **Proposal path (production DVT path):** guardian 1 calls `dvt.createProposal(0, 0, …)`, then `dvt.executeWithProof(1, [target], [50], epoch 1, 2-of-3 aggregate)`. That goes through `BLSAggregator.verifyAndExecute`, then `Registry.batchUpdateGlobalReputation`, where Registry independently re-verifies the proof.
- **Script:** `RehearseReputationBranch.s.sol`. 19 transactions, receipts 19/19 status 1 (`rep-broadcast.json`, `rep-branch.log`).

### Readback (`rep-readback.txt`)
- `globalReputation(target) = 50`
- `agg.executedProposals(1) = true`
- thresholds 2/2
- slots 1/2/3 = guardians 1/2/3
- `requireHealthy` passed inside the script

### Controls (eth_call)
| # | Case | Result |
|---|---|---|
| PC | fresh 2-of-3 proof for proposal 2 | **accepted** (`0x`) |
| N1 | replay of the executed proof on proposal 1 | `ProposalExecutedAlready()` |
| N2 | proof of proposal 1 applied to proposal 2 | `SignatureVerificationFailed()` |
| N3 | proof of proposal 1 with the score changed to 150 | `SignatureVerificationFailed()` |
| N4 | direct `Registry.batchUpdateGlobalReputation` from a non-source | `UnauthorizedSource()` |
| N5 | non-validator calls `executeWithProof` | `NotAuthorizedExecutor()` |
| N6 | fresh 1-of-3 proof (below the default threshold) | `InvalidSignatureCount(uint256,uint256)` |

The positive control shares N2's proposal, inputs and signers. That is the evidence N2/N3 fail because the signature is bound to (domain, proposalId, users, scores, epoch), and not for some unrelated reason.

### Not covered
- The slash branch: slashing is out of scope for 5.5.0.
- Real Safe 2-of-3 execution: the Safe was impersonated.
