#!/bin/bash
# R2-F4: recreate the throwaway G re-run tree /tmp/f4g from committed inputs only:
#   - git worktree of v5.5.0-rc.4 (fbd74fb1) + submodules at the recorded gitlinks
#   - fixture/Rams2a.t.sol.txt              -> contracts/test/zz_rams2a/Rams2a.t.sol
#   - fixture/SuperPaymasterV55Gas.artifact-run.t.sol.txt -> contracts/test/v2/SuperPaymasterV55Gas.t.sol
#   - f4art/<Name>.json = committed artifacts/ (rc.4 forge 1.7.1 profile.default), sha256-checked
#     against checksums/f4art.sha256.txt
# Usage: scripts/setup_f4g.sh   (run from anywhere inside the SuperPaymaster checkout)
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
R=$(git -C "$D" rev-parse --show-toplevel)
T=/tmp/f4g
[ -e $T ] || git -C "$R" worktree add $T fbd74fb1e2e9d948996e6d6c02c48dc1c1778107
git -C $T submodule update --init --recursive
mkdir -p $T/contracts/test/zz_rams2a $T/f4art $T/f4dump
cp "$D/fixture/Rams2a.t.sol.txt" $T/contracts/test/zz_rams2a/Rams2a.t.sol
cp "$D/fixture/SuperPaymasterV55Gas.artifact-run.t.sol.txt" $T/contracts/test/v2/SuperPaymasterV55Gas.t.sol
A=$D/artifacts
cp $A/AOAProtocolRegistry.sol/AOAProtocolRegistry.json     $T/f4art/AOAProtocolRegistry.json
cp $A/ERC1967Proxy.sol/ERC1967Proxy.default.json           $T/f4art/ERC1967Proxy.json
cp $A/GlobalTierSource.sol/GlobalTierSource.json           $T/f4art/GlobalTierSource.json
cp $A/SimpleAccountFactory.sol/SimpleAccountFactory.default.json $T/f4art/SimpleAccountFactory.json
cp $A/SuperPaymaster.sol/SuperPaymaster.json               $T/f4art/SuperPaymaster.json
cp $A/xPNTsFactoryV2.sol/xPNTsFactoryV2.json               $T/f4art/xPNTsFactoryV2.json
cp $A/xPNTsTokenV2.sol/xPNTsTokenV2.json                   $T/f4art/xPNTsTokenV2.json
cp $A/xPNTsTokenV2Ext.sol/xPNTsTokenV2Ext.json             $T/f4art/xPNTsTokenV2Ext.json
(cd $T && sha256sum -c "$D/checksums/f4art.sha256.txt")
(cd $D && sha256sum -c checksums/fixture.sha256.txt 2>/dev/null | grep -E 'Rams2a|artifact-run.t.sol')
echo "contracts/src tree $(git -C $T rev-parse HEAD:contracts/src)  foundry.toml $(git -C $T rev-parse HEAD:foundry.toml)"
