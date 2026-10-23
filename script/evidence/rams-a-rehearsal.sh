#!/usr/bin/env bash
# Offline compilation is supported. Fork reads require the orchestrator's archive RPC.
# Example: FORGE=/path/to/nightly/forge SEPOLIA_FORK_RPC=... FORK_BLOCK=... \
#   OPERATORS=0x...,0x... ./script/evidence/rams-a-rehearsal.sh --hardfork amsterdam
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
forge_bin="${FORGE:-forge}"
if ! command -v "$forge_bin" >/dev/null 2>&1; then
    printf 'Forge binary unavailable: %s (set FORGE to its path)\n' "$forge_bin" >&2
    exit 127
fi
if [[ -n "${SEPOLIA_FORK_RPC:-}" ]]; then
    : "${FORK_BLOCK:?Set FORK_BLOCK to the pinned Sepolia block}"
    : "${OPERATORS:?Supply the COMPLETE deduplicated operator list from an archive OperatorConfigured log scan}"
fi
log_dir="docs/design/aoa-balance-mode/data/rams-a"
mkdir -p "$log_dir"
log_file="$log_dir/rehearsal-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
export FOUNDRY_ISOLATE=false
export FOUNDRY_OFFLINE=true
# pipefail preserves Forge failure; RPC URL and credentials are deliberately never printed.
{
    printf 'Route A rehearsal UTC: %s\n' "$(date -u +%FT%TZ)"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    printf 'FORK_BLOCK=%s\nOPERATORS=%s\nFOUNDRY_ISOLATE=false\n' "${FORK_BLOCK:-unset}" "${OPERATORS:-unset}"
    if [[ -z "${SEPOLIA_FORK_RPC:-}" ]]; then
        printf 'OFFLINE: all fork tests must SKIP. This is not Amsterdam acceptance evidence.\n'
    else
        printf 'Fork run: caller must select nightly --hardfork amsterdam and attest archive inventory completeness.\n'
    fi
    "$forge_bin" --version
    printf 'Arguments:'
    printf ' %q' --match-path contracts/test/rams/RamsARouteRehearsal.t.sol --no-isolate -vvv "$@"
    printf '\n'
    "$forge_bin" test --match-path contracts/test/rams/RamsARouteRehearsal.t.sol --no-isolate -vvv "$@"
} 2>&1 | tee "$log_file"
printf 'Evidence: %s\n' "$log_file"
