// Keep synthetic scenario summaries coherent when a control changes rows/verdicts.
// Never apply this to archive validation or summary-tampering controls.
export function syntheticSummary(a) {
  const start = a[0], end = a.at(-1), rows = a.slice(1, -1);
  end.targetTriplets = start.count;
  end.tally = Object.fromEntries(start.arms.map(arm => [arm, { attempts: 0, verdicts: {} }]));
  end.triplets = [];
  let group = [];
  for (const row of rows) {
    if (row.verdict === 'STOPPED' || row.stoppedBy) break;
    const t = end.tally[row.arm];
    t.attempts++; t.verdicts[row.verdict] = (t.verdicts[row.verdict] ?? 0) + 1;
    group.push(row);
    if (group.length === start.arms.length) {
      end.triplets.push({ tripletIndex: row.tripletIndex,
        matched: start.fixture === null && group.every(r => r.verdict === 'USEROP_SUCCESS' && r.conservation?.evaluated && r.conservation.ok),
        attempts: group.map(r => r.attemptIndex) });
      group = [];
    }
  }
  return a;
}
