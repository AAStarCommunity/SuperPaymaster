#!/bin/zsh
# DSR paper T2 evidence at rc.7 (+ T2 tests). Usage: rc7_t2_runs.sh <outdir>
# Engine: forge 1.7.1 (CI). EVMs: cancun (foundry.toml default) and prague.
# Scope per DSR wording: release tuple comes from DeploymentGasFixtures via SelectedGasFixtures (default at rc.7).
set -u
out=$1; mkdir -p $out; cd ${0:A:h}/../..
F=$HOME/.foundry/bin/forge
S=$out/SUMMARY.txt
echo "HEAD=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ') forge=$($F --version | head -1)" > $S
typeset -A SUITES
SUITES=(
  adversarial    "--match-path contracts/test/v2/SuperPaymasterV55Adversarial.t.sol"
  tuple480       "--match-path contracts/test/v2/SuperPaymasterTuple480.t.sol"
  token_v2       "--match-path contracts/test/v2/xPNTsTokenV2.t.sol"
  invariants     "--match-path 'contracts/test/{invariant/*.invariant.t.sol,v2/xPNTsTokenV2Invariant.t.sol}'"
  g2_replay      "--match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol --match-test test_G2_coverage_replay_fixed_seeds"
)
for evm in cancun prague; do
  for k in adversarial tuple480 token_v2 invariants g2_replay; do
    log=$out/$evm-$k.log
    eval nice -n 10 $F test --evm-version $evm ${SUITES[$k]} -vv > $log 2>&1 </dev/null; rc=$?
    echo "[$evm] $k rc=$rc :: $(grep -E '^Ran [0-9]+ test suite' $log | tail -1)" >> $S
  done
done
echo "HEAD_AFTER=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ')" >> $S
echo DONE >> $S
