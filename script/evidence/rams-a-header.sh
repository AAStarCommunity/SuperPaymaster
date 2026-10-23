#!/usr/bin/env bash
# Shared evidence header. Never print an RPC URL or its actual host.
rams_header() {
    printf 'Route A evidence UTC: %s\n' "$(date -u +%FT%TZ)"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    # Uncommitted changes make the commit line meaningless; record them (paths only).
    printf 'Dirty paths: %s\n' "$(git status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
    git status --porcelain --untracked-files=all | sed 's/^/  dirty: /'
    "$forge_bin" --version
    printf 'FORK_BLOCK=%s\nOPERATORS=%s\nRPC host: <redacted>\nFOUNDRY_ISOLATE=false\n' "${FORK_BLOCK:-unset}" "${OPERATORS:-unset}"
    printf 'Command:'; printf ' %q' "$forge_bin" "$@"; printf '\n'
}
