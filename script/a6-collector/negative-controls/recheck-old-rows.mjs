// For each row the PREVIOUS collector wrote, look up the EntryPoint UserOperationEvent for the
// userOpHash that row recorded, in that row's own tx receipt — i.e. what the old row SHOULD have said.
// Usage: node recheck-old-rows.mjs <rpc> <entryPoint> <old.jsonl>
import { readFileSync } from 'node:fs';
import { createPublicClient, http } from 'viem';
import { decodeLogsFrom, EP_EVENTS_ABI } from '../gauge-lib.mjs';
const [rpcUrl, ep, file] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpcUrl)) { console.error('local only'); process.exit(2); }
const pub = createPublicClient({ transport: http(rpcUrl) });
const out = [];
for (const line of readFileSync(file, 'utf8').trim().split('\n')) {
  const r = JSON.parse(line);
  const rc = await pub.getTransactionReceipt({ hash: r.txHash });
  const ev = decodeLogsFrom(rc.logs, ep, EP_EVENTS_ABI);
  const mine = ev.filter((e) => e.event === 'UserOperationEvent' && e.args.userOpHash.toLowerCase() === r.userOpHash.toLowerCase());
  const reason = ev.filter((e) => e.event === 'UserOperationRevertReason' && e.args.userOpHash.toLowerCase() === r.userOpHash.toLowerCase());
  out.push({ paymasterKind: r.paymasterKind, oldRecorded: { status: r.status, infraFailure: r.infraFailure, sponsorshipFailed: r.sponsorshipFailed },
    receiptStatus: rc.status, userOpEventForRecordedHash: mine.length ? { success: mine[0].args.success } : null,
    otherUserOpEventHashes: ev.filter((e) => e.event === 'UserOperationEvent' && !mine.includes(e)).map((e) => e.args.userOpHash),
    userOperationRevertReason: reason.map((e) => e.args.revertReason) });
}
console.log(JSON.stringify(out, null, 2));
