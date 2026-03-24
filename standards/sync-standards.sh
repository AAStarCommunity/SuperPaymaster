#!/usr/bin/env bash
# ==============================================================================
# Standards Tracker — Auto-sync and diff all tracked specifications
# ==============================================================================
# Usage:
#   ./standards/sync-standards.sh          # Pull + show summary
#   ./standards/sync-standards.sh --diff   # Pull + show detailed changes
#   ./standards/sync-standards.sh --watch  # Pull + show changes for key files only
# ==============================================================================

set -e
cd "$(dirname "$0")/.."

MODE="${1:---summary}"
STANDARDS_DIR="standards"

echo "=========================================="
echo "  Standards Tracker — $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="
echo ""

# Key files to watch in each submodule (function-based lookup, macOS bash 3.x compatible)
get_watch_files() {
    case "$1" in
        x402)      echo "specs/x402-specification-v2.md specs/schemes/exact/scheme_exact_evm.md typescript/packages/core/src" ;;
        mpp-specs) echo "specs/ README.md" ;;
        ercs)      echo "ERCS/erc-8004.md ERCS/erc-3009.md ERCS/erc-4337.md ERCS/erc-7710.md ERCS/erc-7683.md" ;;
        permit2)   echo "src/SignatureTransfer.sol src/AllowanceTransfer.sol" ;;
        *)         echo "" ;;
    esac
}

# Initialize submodules if needed
echo "Initializing submodules..."
git submodule init 2>/dev/null || true
git submodule update --init 2>/dev/null || true
echo ""

# Track changes per submodule
TOTAL_CHANGES=0
ROOT_DIR=$(pwd)

for SUBMOD_PATH in "$STANDARDS_DIR"/*/; do
    SUBMOD_NAME=$(basename "$SUBMOD_PATH")

    # Skip non-directories
    [ ! -d "$SUBMOD_PATH/.git" ] && [ ! -f "$SUBMOD_PATH/.git" ] && continue

    echo "----------------------------------------"
    echo "  $SUBMOD_NAME"
    echo "----------------------------------------"

    cd "$SUBMOD_PATH"

    # Get current commit before pull
    OLD_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
    OLD_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "???")

    # Fetch and pull latest
    echo "  Fetching latest..."
    git fetch origin --quiet 2>/dev/null || { echo "  [WARN] Fetch failed (network?)"; cd "$ROOT_DIR"; continue; }

    DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
    [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

    git checkout "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
    git pull origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true

    NEW_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
    NEW_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "???")

    if [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
        echo "  Up to date ($NEW_SHORT)"
    else
        COMMIT_COUNT=$(git log --oneline "$OLD_COMMIT".."$NEW_COMMIT" 2>/dev/null | wc -l | tr -d ' ')
        TOTAL_CHANGES=$((TOTAL_CHANGES + COMMIT_COUNT))
        echo "  Updated: $OLD_SHORT -> $NEW_SHORT ($COMMIT_COUNT new commits)"
        echo ""

        # Show commit log
        echo "  Recent changes:"
        git log --oneline --no-merges "$OLD_COMMIT".."$NEW_COMMIT" 2>/dev/null | head -15 | while read -r line; do
            echo "    - $line"
        done

        if [ "$MODE" = "--diff" ]; then
            echo ""
            echo "  File changes:"
            git diff --stat "$OLD_COMMIT".."$NEW_COMMIT" 2>/dev/null | head -20 | while read -r line; do
                echo "    $line"
            done
        fi

        if [ "$MODE" = "--watch" ]; then
            WATCH=$(get_watch_files "$SUBMOD_NAME")
            if [ -n "$WATCH" ]; then
                echo ""
                echo "  Watched file changes:"
                for PATTERN in $WATCH; do
                    CHANGED=$(git diff --name-only "$OLD_COMMIT".."$NEW_COMMIT" -- "$PATTERN" 2>/dev/null)
                    if [ -n "$CHANGED" ]; then
                        echo "$CHANGED" | while read -r f; do
                            echo "    * $f"
                        done
                    fi
                done
            fi
        fi
    fi

    echo ""
    cd "$ROOT_DIR"
done

echo "=========================================="
if [ "$TOTAL_CHANGES" -gt 0 ]; then
    echo "Total: $TOTAL_CHANGES new commits across all standards"
else
    echo "All standards up to date"
fi
echo "=========================================="

# Show tracked standards summary
echo ""
echo "Tracked Standards:"
echo "  x402        — Coinbase/Cloudflare x402 protocol (specs + SDK)"
echo "  mpp-specs   — Stripe/Tempo Machine Payments Protocol specs"
echo "  ercs        — Ethereum ERCs (ERC-8004, ERC-3009, ERC-4337, ERC-7710)"
echo "  permit2     — Uniswap/Paradigm Permit2 contracts"
echo ""
echo "Run with --diff for detailed file changes"
echo "Run with --watch for key file monitoring only"
