#!/usr/bin/env bash
# Freshness gate for contracts/test/crossrepo/vendor/.
#
# The offline half of this problem is already covered, and covered where it cannot be
# skipped: contracts/test/crossrepo/VendoredProvenanceSelfCheck.t.sol re-runs each
# header's own recipe and pins each file byte-for-byte, so any LOCAL edit — body or
# header — turns the suite red. That test can prove the copy still matches the commit
# it names. It cannot prove that commit is still the one worth naming.
#
# This script closes only the second half, and it needs the network, which is exactly
# why it is not a unit test:
#
#   CHECK 1 (pin integrity)  the pinned commit's file still hashes to the recorded sha
#   CHECK 2 (pin freshness)  upstream's default branch still has that same content
#
# CHECK 1 alone does not stop staleness: a pin can be perfectly intact and years old.
#
# FAIL-CLOSED. A network error, a missing credential or an unreachable remote exits
# non-zero with UNRESOLVED. It never prints OK for "nothing came back" — an empty or
# failed answer is indistinguishable from a clean one, which is the same trap
# docs/security/CC48-safe-onboarding-runbook.md section 5b documents for event scans.
#
# Usage:   scripts/check-vendored-drift.sh
# Local:   DVT_REPO_PATH=/path/to/YetAnotherAA-Validator scripts/check-vendored-drift.sh
set -uo pipefail

UPSTREAM_REPO="AAStarCommunity/YetAnotherAA-Validator"
PINNED_COMMIT="8395c94c"

# vendored file : upstream path : sha256 recorded in the vendored header
ENTRIES=(
  "contracts/test/crossrepo/vendor/OverIssueFraudProofVerifier.sol:contracts/src/verifiers/OverIssueFraudProofVerifier.sol:6616d5a70af6bd4dedd1982d5874376c014430cdad8af1e0e461bdb120af33ec"
  "contracts/test/crossrepo/vendor/IFraudProofVerifier.sol:contracts/src/interfaces/IFraudProofVerifier.sol:4d96d411af30e4d384232f48743f0b31f70e1bb3afd16af5e64f16a4421dbe65"
)

unresolved=0
drift=0

# Contact the remote ONCE, up front, and refuse to continue if we could not. In the local
# -repo mode this is the whole ballgame: `git show origin/<branch>:path` reads a CACHED ref
# that can be arbitrarily old, so a swallowed fetch failure produces a check-2 that never
# touched the network and still prints "still current". That is the one outcome this script
# exists to make impossible, so a fetch failure is UNRESOLVED, never a pass.
require_live_remote() {
  if [[ -n "${DVT_REPO_PATH:-}" && -d "${DVT_REPO_PATH}/.git" ]]; then
    # WHICH remote is itself an unverified quantity. Point DVT_REPO_PATH at a fork, or at
    # another local working clone, and every check below answers truthfully about the wrong
    # repository — and a local clone's HEAD is whatever branch it has checked out, not the
    # upstream default, so even "the default branch" would silently become something else.
    local url
    url="$(git -C "$DVT_REPO_PATH" remote get-url origin 2>/dev/null)"
    if [[ "$url" != *"${UPSTREAM_REPO}"* ]]; then
      echo "UNRESOLVED: $DVT_REPO_PATH has origin '$url', which is not ${UPSTREAM_REPO}."
      echo "            Checks against it would be true statements about the wrong repo."
      exit 2
    fi
    if ! git -C "$DVT_REPO_PATH" fetch -q origin 2>/dev/null; then
      echo "UNRESOLVED: could not fetch from origin in $DVT_REPO_PATH."
      echo "            check 2 would then compare against a cached ref of unknown age,"
      echo "            which cannot establish freshness. This is NOT a pass."
      exit 2
    fi
  fi
}

# $1 = ref, $2 = upstream path, $3 = destination file.
# Writes to a FILE rather than returning content on stdout: command substitution strips
# trailing newlines, and every sha256 recorded in a vendored header was taken over the
# whole file INCLUDING its final newline. Comparing a stripped body against those digests
# reports drift on two identical files — a false alarm that would train readers to ignore
# this gate, which is worse than not having it.
fetch_to() {
  if [[ -n "${DVT_REPO_PATH:-}" && -d "${DVT_REPO_PATH}/.git" ]]; then
    git -C "$DVT_REPO_PATH" show "$1:$2" > "$3" 2>/dev/null
  else
    gh api "repos/${UPSTREAM_REPO}/contents/${2}?ref=${1}" --jq '.content' 2>/dev/null \
      | base64 -d > "$3" 2>/dev/null
  fi
  [[ -s "$3" ]]
}

# The default branch must come from the REMOTE. A local `refs/remotes/origin/HEAD` is just a
# symlink this clone happens to hold; on a real clone here it pointed at
# origin/chore/release-1.15.0, so check 2 would have declared a NON-default branch "still
# current" and exited 0. Ask ls-remote, which cannot be answered from cache.
default_ref() {
  if [[ -n "${DVT_REPO_PATH:-}" && -d "${DVT_REPO_PATH}/.git" ]]; then
    local head
    head="$(git -C "$DVT_REPO_PATH" ls-remote --symref origin HEAD 2>/dev/null \
            | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')"
    [[ -n "$head" ]] && echo "origin/$head"
  else
    gh api "repos/${UPSTREAM_REPO}" --jq '.default_branch' 2>/dev/null
  fi
}

# The commit check 2 actually compared against, so the output names its own evidence rather
# than just asserting freshness.
resolved_sha() {
  if [[ -n "${DVT_REPO_PATH:-}" && -d "${DVT_REPO_PATH}/.git" ]]; then
    git -C "$DVT_REPO_PATH" rev-parse --short "$1" 2>/dev/null
  else
    gh api "repos/${UPSTREAM_REPO}/commits/${1}" --jq '.sha[0:7]' 2>/dev/null
  fi
}

require_live_remote
REF="$(default_ref)"
if [[ -z "$REF" ]]; then
  echo "UNRESOLVED: could not determine ${UPSTREAM_REPO}'s default branch (no network, or no credential)."
  echo "            This is NOT a pass. Re-run where the remote is reachable."
  exit 2
fi
UPSTREAM_SHA="$(resolved_sha "$REF")"
if [[ -z "$UPSTREAM_SHA" ]]; then
  echo "UNRESOLVED: resolved the default branch ($REF) but could not resolve its commit."
  exit 2
fi
echo "upstream default branch: $REF @ $UPSTREAM_SHA"
echo "vendored pin           : $PINNED_COMMIT"

for e in "${ENTRIES[@]}"; do
  local_file="${e%%:*}"; rest="${e#*:}"
  up_path="${rest%%:*}"; want_sha="${rest##*:}"
  echo
  echo "--- $up_path"

  tmp_pin="$(mktemp)"; tmp_head="$(mktemp)"
  trap 'rm -f "$tmp_pin" "$tmp_head"' RETURN 2>/dev/null || true
  if ! fetch_to "$PINNED_COMMIT" "$up_path" "$tmp_pin"; then
    echo "  UNRESOLVED check 1: could not read $up_path at $PINNED_COMMIT"
    unresolved=1; rm -f "$tmp_pin" "$tmp_head"; continue
  fi
  got="$(shasum -a 256 < "$tmp_pin" | cut -d' ' -f1)"
  if [[ "$got" != "$want_sha" ]]; then
    echo "  FAIL check 1 (pin integrity): $PINNED_COMMIT now hashes $got, header records $want_sha"
    drift=1; rm -f "$tmp_pin" "$tmp_head"; continue
  fi
  echo "  ok   check 1 (pin integrity): $PINNED_COMMIT matches the recorded sha256"

  if ! fetch_to "$REF" "$up_path" "$tmp_head"; then
    echo "  UNRESOLVED check 2: could not read $up_path at $REF"
    unresolved=1; rm -f "$tmp_pin" "$tmp_head"; continue
  fi
  head_sha="$(shasum -a 256 < "$tmp_head" | cut -d' ' -f1)"
  if [[ "$head_sha" != "$want_sha" ]]; then
    echo "  STALE check 2 (freshness): $REF hashes $head_sha, the pin holds $want_sha"
    echo "         The vendored copy is behind upstream. Re-vendor, update the header, the"
    echo "         sha constants in VendoredProvenanceSelfCheck.t.sol and PINNED_COMMIT here."
    drift=1; rm -f "$tmp_pin" "$tmp_head"; continue
  fi
  echo "  ok   check 2 (freshness): $REF still carries the pinned content"
  rm -f "$tmp_pin" "$tmp_head"
done

echo
if (( unresolved )); then
  echo "RESULT: UNRESOLVED — at least one check could not complete. Not a pass."
  exit 2
fi
if (( drift )); then
  echo "RESULT: DRIFT — the vendored copies no longer describe upstream."
  exit 1
fi
echo "RESULT: clean — pins intact, and still current as of $REF @ $UPSTREAM_SHA."
