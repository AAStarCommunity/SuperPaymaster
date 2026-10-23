#!/usr/bin/env bash
# Shared evidence header. Never print an RPC URL or its actual host.
rams_header() {
    printf 'Route A evidence UTC: %s\n' "$(date -u +%FT%TZ)"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    local exclusions=()
    [[ -z "${log_file:-}" ]] || exclusions+=(":(exclude)$log_file")
    if [[ -n "${OUT:-}" ]]; then
        exclusions+=(":(exclude)$OUT/CONTROL.log" ":(exclude)$OUT/summary.tsv"
            ":(exclude)$OUT/M*.log" ":(exclude)$OUT/M*.patch.txt")
        # Definitions in D are inputs. Only copies in a separate output directory are outputs.
        [[ "${D:-}" = "$OUT" ]] || exclusions+=(":(exclude)$OUT/M*.diff")
    fi
    local dirty
    dirty=$(git status --porcelain --untracked-files=all -- . "${exclusions[@]}")
    printf 'Dirty paths: %s\n' "$(printf '%s\n' "$dirty" | awk 'NF {n++} END {print n+0}')"
    [[ -z "$dirty" ]] || printf '%s\n' "$dirty" | sed 's/^/  dirty: /'
    "$forge_bin" --version
    printf 'FORK_BLOCK=%s\nOPERATORS=%s\nRPC host: <redacted>\nFOUNDRY_ISOLATE=%s\n' "${FORK_BLOCK:-unset}" "${OPERATORS:-unset}" "${FOUNDRY_ISOLATE:-unset}"
    printf 'Command:'; printf ' %q' "$forge_bin" "$@"; printf '\n'
}

# Strip URL transports, IP:port, and common-TLD RPC host:port or /v2|v3/key forms.
rams_redact() {
    python3 -u -c '
import re, sys
pattern = re.compile(r"(?P<time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)|(?P<url>(?:https?|wss?)://\S+)|(?P<host>(?<![\w.-])(?:\[[0-9a-fA-F:]+\]|(?:\d{1,3}\.){3}\d{1,3}):[0-9]{1,5}[^\s]*|(?<![\w.-])(?:[\w-]+\.)+(?:com|io|org|net|co|xyz|app|dev|cloud|network)(?::[0-9]{1,5}[^\s]*|/v[23]/[^\s]+))")
for line in sys.stdin:
    print(pattern.sub(lambda m: m[0] if m["time"] else "<redacted>" if m["url"] else "<redacted-rpc-host>", line), end="")
'
}
