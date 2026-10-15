// Offline fixtures only: explicit synthetic evidence, never an archive repair.
// Baseline arms do not mutate SP in these fixtures; carry the last SP balance
// into the final baseline readback to exercise the newly required same-hash anchor.
export function syntheticAnchors(a) {
  const end = a.at(-1).passport;
  let balance = a[0].passport.volatile.operatorBalance;
  for (const r of a.slice(1,-1)) {
    if (!r.readbacks) continue;
    if (r.arm === 'SP') balance = r.readbacks.after.A.operatorBalance;
    for (const side of ['before','after']) for (const rpc of ['A','B']) {
      const rb = r.readbacks[side][rpc];
      if (rb.blockHash.toLowerCase() === end.block.hash.toLowerCase() && !('operatorBalance' in rb)) rb.operatorBalance = balance;
    }
  }
  return a;
}
