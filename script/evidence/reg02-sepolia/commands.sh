#!/bin/zsh
# REG-02 Sepolia evidence — exact commands run (read-only; no tx, no signing, no ~/Dev/.env).
# RPC URLs are read from files and never printed; all output piped through the URL scrubber.
C=~/.foundry/bin/cast; A=$(cat ~/Dev/aastar/manifest-live/.rpc/rpca); B=$(cat ~/Dev/aastar/manifest-live/.rpc/rpcb)
SCRUB='s#https?://[^ "]+#<url>#g'
R=0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71   # deployments/config.sepolia.json: registry
S=0x4867B4302bf4C7818b71F55E53A3520Ee1855Aa7   # deployments/config.sepolia.json: sbt
D=/Users/jason/Dev/aastar/manifest-live/reg02-sepolia-evidence; cd $D

# 1. identity
{ $C chain-id -r $A; $C call $R 'version()(string)' -r $A; $C call $R 'version()(string)' -r $B
  $C storage $R 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc -r $A   # EIP-1967 impl slot
  $C codesize $S -r $A; $C call $S 'version()(string)' -r $A; $C call $S 'REGISTRY()(address)' -r $A
  $C call $R 'ROLE_ENDUSER()(bytes32)' -r $A    # reverts: ROLE_* are file-level constants in IRegistry.sol, no getter
  $C keccak ENDUSER                              # ROLE_ENDUSER = keccak256("ENDUSER")
  $C block-number -r $A; $C block-number -r $B; } 2>&1 | sed -E $SCRUB

# 2. topic0s (signatures from origin/main IRegistry.sol / MySBT.sol + git history variants)
for s in 'RoleExited(bytes32,address,uint256,uint256)' 'SBTBurnFailed(address,bytes32)' \
  'RoleRegistered(bytes32,address,uint256,uint256)' 'RoleGranted(bytes32,address,address)' \
  'RoleGranted(bytes32,address,uint256)' 'RoleRevoked(bytes32,address,address)' 'SBTStatusSyncFailed(address,bytes32)' \
  'OwnershipTransferred(address,address)' 'Upgraded(address)' 'Initialized(uint64)' 'BurnExecuted(address,bytes32,uint256,string)'; do
  echo "$($C sig-event "$s") $s"; done > topics.txt
# legacy Registry_v3_0_0 variants (also covered by the unfiltered address query below):
$C sig-event 'RoleExited(address,bytes32,uint256,uint256,uint256,uint256)'
$C sig-event 'RoleRegistered(address,bytes32,uint256,uint256,uint256,uint256)'
for s in 'Transfer(address,address,uint256)' 'SBTMinted(address,uint256,address,uint256)' \
  'SBTBurned(address,uint256,uint256,uint256,uint256)' 'MembershipAdded(uint256,address,string,uint256)' \
  'MembershipDeactivated(uint256,address,uint256)'; do echo "$($C sig-event "$s") $s"; done > sbt_topics.txt

# 3. deployment blocks: binary search on `cast codesize -B` (no scanning)
bs() { local lo=0 hi=$($C block-number -r $A) m s; while [ $((hi-lo)) -gt 1 ]; do m=$(((lo+hi)/2)); s=$($C codesize $1 -B $m -r $A 2>/dev/null); if [ "${s:-0}" -gt 0 ]; then hi=$m; else lo=$m; fi; done; echo "$1 first code at $hi; codesize at $lo = $($C codesize $1 -B $lo -r $A)"; }
bs $R; bs $S      # -> Registry 11151002, MySBT 11151006

# 4. logs (fetch_logs.sh pages 100k blocks, halves a page on error, records GAP below 1000 blocks)
RA=~/Dev/aastar/manifest-live/.rpc/rpca; RB=~/Dev/aastar/manifest-live/.rpc/rpcb
./fetch_logs.sh $RA reg_all_a $R 11151002 12098756 | tee run_reg_all_a.txt   # every Registry log, no topic filter
./fetch_logs.sh $RB reg_all_b $R 11151002 12098756 | tee run_reg_all_b.txt
for ep in a b; do f=$RA; [ $ep = b ] && f=$RB; for t in RoleExited SBTBurnFailed RoleRegistered 'RoleGranted(bytes32,address,address)' 'RoleGranted(bytes32,address,uint256)'; do
  T0=$(grep -F " $t" topics.txt | head -1 | cut -d' ' -f1); lab=$(echo $t | tr -c 'A-Za-z0-9\n' '_'); echo "== $ep $t $T0"
  ./fetch_logs.sh $f t_${ep}_$lab $R 11151002 12098756 $T0 | awk '{print} /^OK/{n+=$3} END{print "TOTAL",n}'; done; done | tee run_topics.txt
./fetch_logs.sh $RA sbt_all_a $S 11151006 12098756 | tee run_sbt_all_a.txt
./fetch_logs.sh $RB sbt_all_b $S 11151006 12098756 | tee run_sbt_all_b.txt
# (python: endpoint a vs b log sets compared as sorted (block,tx,logIndex,topics,data) tuples -> identical; topic0 histogram decoded against abis/*.json)

# 5/6. state reads at block 12098756 for every address seen in RoleRegistered/RoleGranted/MySBT Transfer, on both endpoints
python3 -I state_reads.py $RA a 12098756 | sed -E $SCRUB > state_a_summary.txt
python3 -I state_reads.py $RB b 12098756 | sed -E $SCRUB > state_b_summary.txt
# userRoleCount is `internal` (no getter): read via storage slot keccak(user . 16) (slot 16 from out/Registry.sol/Registry.json
# storageLayout), validated against the count of hasRole()==true over the 7 ROLE_* constants for all 27 users (0 mismatches).
