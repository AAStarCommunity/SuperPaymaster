# SuperPaymaster Release Checklist Template

> Reusable, version-agnostic checklist for shipping a new SuperPaymaster release.
> Copy this file to `docs/release/<version>-release-log.md` and fill in the evidence
> (commits, PRs, addresses, tx hashes) as you execute each step.

## How to use this template

- A "release" is **NOT** just deploying bytecode on-chain. It is: reviewed code →
  verified deploy → real E2E proof → published artifacts → synced downstream consumers
  → governance handoff. A step left undone is a half-done release.
- Each item is tagged:
  - **[BLOCK]** = release-blocking. Do not declare the release done until this is green.
  - **[NICE]** = nice-to-have / can be deferred with an explicit note.
  - Owner: **(eng)** engineering-owned, **(ops)** operations-owned.
- Every **[BLOCK]** item must carry **concrete evidence** in the release log (a commit
  SHA, PR number, on-chain address, tx hash, or Etherscan link). "Looks done" is not done.

### Legend

| Tag | Meaning |
|-----|---------|
| `[BLOCK]` | Release cannot ship without this |
| `[NICE]` | Desirable, may be deferred with a written reason |
| `(eng)` | Owned by engineering |
| `(ops)` | Owned by operations / governance |

---

## Phase 0 — Pre-release / Code Freeze

Goal: agree on scope, version, and branch strategy before any code lands.

- [ ] **[BLOCK] (eng)** Decide the version number per **Semantic Versioning** (`MAJOR.MINOR.PATCH`,
      with `-beta.N` / `-rc.N` pre-release suffix). MAJOR = breaking ABI/storage change,
      MINOR = backward-compatible feature, PATCH = backward-compatible fix.
- [ ] **[BLOCK] (eng)** Cut a release branch (`release/<version>`) off the integration branch.
      All release-prep commits land on this branch via PR — never directly on `main`.
- [ ] **[BLOCK] (eng)** Freeze scope: list every contract changed and the storage/ABI impact
      (none / additive / breaking). Breaking storage changes require a storage-layout review (Phase 1).
- [ ] **[BLOCK] (eng)** Plan the `version()` string bump for every contract whose bytecode changed
      (e.g. `"SuperPaymaster-X.Y.Z"`). Record the target string now; verify it on-chain in Phase 4.
- [ ] **[NICE] (eng)** Draft the CHANGELOG entry (Added / Changed / Fixed / Security / Removed).
- [ ] **[NICE] (eng)** Confirm compiler settings are locked and unchanged unless intentional
      (Solidity version, optimizer runs, EVM target, via-IR). A silent settings drift changes bytecode
      and codehash.

---

## Phase 1 — Code Review & Test

Goal: prove the code is correct and within deployment limits, with no false-green.

- [ ] **[BLOCK] (eng)** Full test suite passes locally: `forge test`. Record pass count and 0 failures.
- [ ] **[BLOCK] (eng)** `forge build` clean; **EIP-170 byte-size check** for every deployed contract
      (≤ 24,576 bytes). Record each contract's runtime size and the headroom remaining.
- [ ] **[BLOCK] (eng)** Fuzz / invariant pass where applicable (Echidna configs, Foundry invariant tests).
- [ ] **[BLOCK] (eng)** **Adversarial external review** before declaring done. Run a strict,
      adversarial reviewer (e.g. Codex) over the diff — correctness, race conditions, signature/typehash
      correctness, nonce/replay handling, access control, storage safety. **Iterate until it approves.**
      Record how many rounds and what was caught/fixed each round. A single clean pass with no findings on
      a large diff is itself a yellow flag — challenge it.
- [ ] **[BLOCK] (eng)** Static analysis (Slither or equivalent) reviewed; new findings triaged
      (fixed or explicitly accepted with reason).
- [ ] **[BLOCK] (eng)** `forge fmt --check` clean; no formatting-only noise in the release diff.
- [ ] **[BLOCK] (eng)** **Storage-layout safety** for upgradeable contracts: new vars only appended,
      removed vars replaced with deprecated placeholders (never reordered/deleted), `__gap` reduced by
      exactly the number of slots consumed. Verify with `forge inspect <C> storage-layout` against the
      previous release's layout.
- [ ] **[BLOCK] (eng)** All review PRs **merged** (not just approved) into the release branch.
- [ ] **[NICE] (eng)** Gas snapshot diff reviewed for unexpected regressions.

---

## Phase 2 — Deploy Scripts Ready

Goal: the deploy path is complete, idempotent, and proven in simulation — not a one-off manual bus.

- [ ] **[BLOCK] (eng)** New contracts are wired into the **canonical deploy entrypoint**
      (`./deploy-core` → `DeployLive.s.sol` / `UpgradeLive.s.sol` / `DeployAnvil.s.sol`), not only a
      throwaway one-shot script. `./deploy-core <env>` must produce a **complete** deployment of the new
      version. Prefer a shared bootstrap library so anvil/sepolia/live paths stay in sync.
- [ ] **[BLOCK] (eng)** Deploy scripts are **idempotent**: re-running skips already-deployed/unchanged
      contracts (srcHash / address-presence guard) and does not double-deploy or brick wiring.
- [ ] **[BLOCK] (eng)** **Fork simulation** of the full deploy/upgrade against a fork of the target
      network passes end-to-end (every txn simulated, wiring calls included). Record the txn count.
- [ ] **[BLOCK] (eng)** Upgrade vs fresh-deploy decision documented per contract:
      UUPS `upgradeTo` for proxied contracts (Registry, SuperPaymaster), fresh deploy + re-wire for the rest.
- [ ] **[BLOCK] (eng)** Post-deploy wiring is scripted (setters, role grants, slasher authorizations),
      not left as manual console steps.
- [ ] **[NICE] (eng)** Dry-run / `--resume`-safe: a mid-run failure can be resumed without corrupting state.

---

## Phase 3 — Deploy

Goal: get the new bytecode on-chain with **proof the transactions actually mined** (no ghost nonces).

- [ ] **[BLOCK] (ops)** Confirm deployer signer & funds (keystore account preferred over plaintext key);
      separate deployer per environment.
- [ ] **[BLOCK] (ops)** **RPC reliability — the ghost-nonce lesson.** Some providers (e.g. Alchemy) may
      *accept* a transaction via `eth_sendRawTransaction` but never broadcast it to the mempool — the local
      nonce advances while the network nonce does not, and `forge --slow` hangs forever waiting for a receipt.
      Mitigation:
  - [ ] Cross-check the **network nonce** via a second, propagating node (e.g. publicnode) with
        `curl eth_getTransactionCount latest` — if it lags the local nonce, txns are stuck (ghost).
  - [ ] **Rebroadcast through a node that actually propagates** (redundant broadcast), then poll for the receipt.
  - [ ] Never trust "submitted" as "mined" — a deploy isn't done until receipts exist.
- [ ] **[BLOCK] (ops)** Record every deployed address (impl + proxy for upgradeable contracts).
- [ ] **[BLOCK] (ops)** Record the deployer nonce delta and confirm **every** expected txn is mined
      (nonce advanced by N, N receipts present).
- [ ] **[NICE] (ops)** Save the raw broadcast/`run-latest.json` artifact for audit.

---

## Phase 4 — On-chain Verification

Goal: prove the right code is at the right addresses and is publicly verifiable.

- [ ] **[BLOCK] (eng/ops)** Each deployed address has **non-empty code** (`eth_getCode` ≠ `0x`).
- [ ] **[BLOCK] (eng/ops)** For each UUPS proxy, read **ERC-1967 implementation slot**
      (`0x360894...bbc`) and confirm it points to the **new** impl address.
- [ ] **[BLOCK] (eng/ops)** **Codehash match, not just slot.** Compare the on-chain runtime codehash of
      the impl against the locally compiled artifact. The impl-slot pointing somewhere is not proof the
      *right* bytecode is there — verify the codehash.
- [ ] **[BLOCK] (eng/ops)** **Etherscan source verification** for every new impl/contract; confirm the
      verified source's codehash matches on-chain (so downstream readers see real ABI + source).
- [ ] **[BLOCK] (eng/ops)** Run **post-deploy on-chain check scripts** (Check01–Check0N / VerifyVx):
      roles, owners, wiring pointers, oracle config, fee params all correct. Record pass/fail per check.
- [ ] **[BLOCK] (eng)** Confirm `version()` returns the expected string on-chain for every bumped contract
      — or, if the bump is intentionally deferred, **record the discrepancy explicitly** (impl content vs
      version string) so it is not mistaken for a regression.

---

## Phase 5 — E2E Validation

Goal: prove the system works with **real on-chain transactions**, with reliable exit codes and challenged evidence.

- [ ] **[BLOCK] (eng)** Core happy-path E2E against the live deployment with **real txns** (e.g. gasless
      sponsorship): record tx hashes and an observable state change (e.g. token balance burn before→after).
- [ ] **[BLOCK] (eng)** Feature-specific E2E for everything new this release (e.g. x402 direct settle,
      EIP-3009 settle): record tx hashes, typehash correctness, and **replay-rejection** proof for any
      signature/nonce path.
- [ ] **[BLOCK] (eng)** **No false-green.** E2E scripts must **exit non-zero on failure.** A script that
      `exit 0`s regardless of the underlying result will report green while broken. Audit every script's
      exit-code path and assert on actual results, not just "ran without throwing."
- [ ] **[BLOCK] (eng)** **ABI used by E2E reflects the deployed contracts.** Stale ABIs (referencing
      removed/renamed functions, e.g. functions that no longer exist) silently break or mislead — regenerate
      and clean ABIs before E2E.
- [ ] **[BLOCK] (eng)** **Adversarially challenge the E2E evidence.** Have a strict reviewer inspect the
      results for false-green, stale ABI, and UUPS codehash mismatch. Fix all findings, then **re-run green**
      with verified-reliable exit codes. Record the round.
- [ ] **[NICE] (eng)** Pre-flight idempotent setup (auto-fund/mint test accounts, skip-if-passed, network
      retry on RPC flake) so reruns are robust and don't false-SKIP for lack of funds.

---

## Phase 6 — Publish Artifacts

Goal: make the release discoverable and consumable. The on-chain part is only half.

- [ ] **[BLOCK] (eng)** **GitHub Release** created via **`gh release create <tag>`** (a git tag ALONE is
      NOT a release and does NOT appear on the repo homepage). **Mark it `--latest` (NOT `--prerelease`),
      even for beta/rc** — GitHub's homepage "Releases" widget only surfaces the *Latest* (non-prerelease)
      release, so a `--prerelease` beta is invisible on the repo homepage (this bit us in v5.4.0-beta.1:
      the release existed but was prerelease-only, so the homepage showed nothing). Notes must include the
      version, deployed addresses, changelog, and verification status.
- [ ] **[BLOCK] (eng)** **ABI files + manifest** regenerated and committed, including every new contract.
      The manifest must reflect what was actually deployed (addresses + ABIs in sync).
- [ ] **[BLOCK] (eng)** **Deploy record** doc updated with addresses, tx hashes, and the real E2E hashes.
- [ ] **[BLOCK] (eng)** **README** (all languages maintained, e.g. EN + 中文) + **API docs** updated to the
      new addresses/version. Regenerate auto-generated API docs (record contract/function counts).
- [ ] **[BLOCK] (eng)** **CHANGELOG** finalized for the version.
- [ ] **[NICE] (eng)** Strategy/architecture memo for notable design decisions in this release.

---

## Phase 7 — Downstream Sync

Goal: notify and unblock consumers — **without** pushing changes into repos you don't own.

- [ ] **[BLOCK] (eng)** **Cross-repo changes go via ISSUES, not PRs into other repos.** Open an issue in
      the downstream repo (e.g. the SDK repo) describing the new addresses/ABIs/version and let that repo's
      owners do their own sync. Do **not** open a PR against another repo. (If one was opened by mistake,
      close it and convert to an issue.)
- [ ] **[BLOCK] (eng)** Publish a **canonical address table** for the release (all deployed addresses,
      network, version) and reference it from the relevant cross-repo tracking issues.
- [ ] **[NICE] (eng)** Audit-forward: link the release/audit findings into the relevant downstream tracking
      issues so consumers inherit the security context.
- [ ] **[NICE] (eng)** Notify consumers (changelog link + migration notes) through the agreed channel.

---

## Phase 8 — Governance / Ops Handoff

Goal: hand control to the right keys and make the deployment observable. Mostly ops-owned.

- [ ] **[BLOCK] (ops)** **Ownership / upgrade authority transfer** to the multisig (and/or TimelockController).
      Never leave upgrade rights on a single deployer EOA in production. This is an **ops task**, tracked
      separately from the eng release; if deferred for a beta, record it as deferred explicitly.
- [ ] **[BLOCK] (ops)** Confirm `_authorizeUpgrade` / owner is the intended multisig/timelock on-chain.
- [ ] **[NICE] (ops)** Timelock delay configured and documented (gives auditors/users reaction time before
      an upgrade executes).
- [ ] **[BLOCK] (ops)** **Address handoff to dependents**: hand the canonical address table to every
      dependent system/team that hardcodes or caches addresses.
- [ ] **[NICE] (ops)** Monitoring / alerting wired (balance solvency, paused state, oracle staleness,
      upgrade events).

---

## Phase 9 — Post-release

Goal: be ready for the next fix and capture what we learned.

- [ ] **[BLOCK] (eng)** Open a **bugfix branch** (`fix/<version>`) so post-release fixes don't pollute the
      next feature line.
- [ ] **[NICE] (eng)** Write/refresh the **operational runbook** (deploy, upgrade, rollback, incident).
- [ ] **[NICE] (eng/ops)** **Retrospective**: capture lessons (especially RPC/infra surprises, review-round
      counts, false-green catches) into project memory so the next release starts ahead.

---

## Appendix A — Hard-won lessons baked into this checklist

These are SuperPaymaster-specific lessons that the generic items above encode:

1. **A release ≠ a deploy.** On-chain bytecode is one phase of nine. SDK/README/API/deploy-record/CHANGELOG
   sync (Phase 6–7) is part of the release.
2. **Adversarial review before "done"** (Phase 1 & 5). Multi-round strict review catches typehash/nonce bugs,
   sentinel half-fixes, false-green, and missing platform support that a single self-review misses.
3. **No false-green E2E** (Phase 5). Scripts must `exit` non-zero on failure; assert on real on-chain results.
4. **ABI/manifest must match deployment** (Phase 5 & 6). Stale ABIs referencing non-existent functions
   silently mislead.
5. **Cross-repo = issues, not PRs** (Phase 7). Don't push PRs into repos you don't own (e.g. the SDK repo);
   open an issue and let owners sync.
6. **Deploy scripts must be updated with contract structure** (Phase 2). Fold new contracts into the canonical
   `deploy-core` path via a shared bootstrap so the deploy stays complete and reproducible — not a one-shot
   manual script.
7. **RPC ghost-nonce** (Phase 3). A provider can accept a txn without broadcasting it; cross-check the network
   nonce on a second node and rebroadcast through one that propagates.
8. **Verify codehash, not just the impl slot** (Phase 4). The slot pointing somewhere isn't proof the right
   bytecode is there.

## Appendix B — Sources / further reading

Industry best practices synthesized into this template:

- [12 Solidity Smart Contract Security Best Practices — Alchemy](https://www.alchemy.com/overviews/smart-contract-security-best-practices)
- [How to Deploy and Verify Solidity Smart Contracts — Medium](https://medium.com/@kadyrov_dev/how-to-deploy-and-verify-solidity-smart-contracts-b843d4fa4ecc)
- [Deploying a smart contract using Foundry — Base Docs](https://docs.base.org/learn/foundry/deploy-with-foundry)
- [semantic-release — automated version management & publishing](https://github.com/semantic-release/semantic-release)
- [Upgradeable Smart Contracts: Proxies, Patterns, Pitfalls and CI/CD Safeguards — Octane Security](https://www.octane.security/post/upgradeable-smart-contracts-proxies-patterns-pitfalls-cicd-safeguards)
- [Understanding the UUPS Proxy Pattern — KupiaSec / Medium](https://medium.com/@kupiasec/understanding-the-uups-proxy-pattern-for-upgradeable-ethereum-smart-contracts-7b58bce62f6e)
- [DeFi Upgrade Governance Mechanisms — Nadcab](https://www.nadcab.com/blog/defi-protocol-upgrade-governance)
