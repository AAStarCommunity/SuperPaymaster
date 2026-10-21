# v5.5.0-rc.2 review pack

**AUDIT STATUS: PENDING — this is NOT an audit and no independent audit has been performed.**

Target: annotated tag `v5.5.0-rc.2`, peeled commit `1ac0e1c595dc84e684b540ca6a936168e922194f`. `git diff --stat 1ac0e1c5 HEAD -- contracts/src` is **empty**. Source references in this pack use `path:line` at that pin. No build, Forge test, or Halmos command was run to prepare this pack.

Start with [AUDIT-SCOPE.md](AUDIT-SCOPE.md) for the ten attested contracts, hashes, roles, state writers, scope and open items. [R1-3-ADVERSARIAL-INDEX.md](R1-3-ADVERSARIAL-INDEX.md) maps Reviewer 1 Major Comment 3's six attacker classes to source gates, exact tests, mutations, archived results, and gaps. `EVIDENCE.sha256` checks the three Markdown files in this directory.

The hash source is `docs/release/v5.5.0-rc.2-attestation.json`; archived result paths are under `docs/design/aoa-balance-mode/data/`. Recompute this pack's hashes from the repository root with:

```sh
cd docs/release/v5.5.0-rc.2-review-pack
shasum -a 256 -c EVIDENCE.sha256
```

**Reading rule:** local PASS applies only to its exact test and archived tree. The D5b per-test unit log predates rc.2; the rc.2 attestation gives aggregate Forge counts but no per-test R1-3 trace. The rc.2 D5c-1 rerun and I9 symbolic run are **INCONCLUSIVE**; A2/A2a independent acceptance and A4/A6 public-chain evidence remain open. The 5.4.2→rc.2 same-bundle test demonstrates a concrete incompatibility, requiring the documented pause/drain and separate upgrade procedure.
