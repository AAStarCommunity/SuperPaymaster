#!/usr/bin/env bash
# CI Required Shim — 300-file path-filter bypass guard.
#
# GitHub stops evaluating a workflow's `paths` / `paths-ignore` filters when a PR
# changes more than 300 files, and triggers the workflow regardless. ci-required-
# shim.yml is supposed to fire ONLY when no contract code changed (it reports a
# green status under the same names as the real required checks). Under the
# 300-file rule it can therefore fire on a CONTRACT-touching PR and falsely
# satisfy a required check before real CI has run.
#
# This guard re-checks the actual diff inside the shim job and FAILS (refusing to
# satisfy the required check) whenever a contract-related path changed, forcing
# the real test.yml / security.yml workflows to be the ones that report status.
#
# Keep the path set below in sync with the UNION of test.yml's and security.yml's
# `paths:` lists (and ci-required-shim.yml's `paths-ignore:`).
set -euo pipefail

: "${BASE_SHA:?BASE_SHA required}"
: "${HEAD_SHA:?HEAD_SHA required}"

CONTRACT_PATHS='^(contracts/|singleton-paymaster/|foundry\.toml$|remappings\.txt$|echidna.*\.yaml$|\.github/workflows/(test|security)\.yml$)'

# Three-dot diff (merge-base..head): only the PR's OWN changes, not whatever the
# base branch advanced past since the PR forked. A two-dot diff would falsely
# flag base-branch edits to contract paths the PR never touched.
changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}")"

if echo "${changed}" | grep -qE "${CONTRACT_PATHS}"; then
  echo "::error::Contract-path changes detected — real CI must run; shim refuses to satisfy this required check (GitHub >300-file path-filter bypass guard)."
  echo "Offending changed files:"
  echo "${changed}" | grep -E "${CONTRACT_PATHS}"
  exit 1
fi

echo "No contract-path changes — shim satisfies the required check."
