// Local JSON-RPC pass-through proxy used as read-back endpoint "B" in local Anvil runs.
//
// On a local run there is only one chain, so endpoint A (anvil directly) and endpoint B (this
// proxy in front of the SAME anvil) are NOT independent sources — B exists to exercise the
// collector's A/B comparison path, and, with --tamper, to prove that a disagreement stops the run
// (negative control d). A real campaign must point A and B at two independently operated nodes.
//
// Usage: node rpc-proxy.mjs --listen 8546 --upstream http://127.0.0.1:8545 \
//          [--tamper-selector 0x70a08231 --tamper-to 0x<token> --tamper-add 1]
// With --tamper-*, every eth_call whose `to` and calldata selector match gets its uint256 result
// increased by --tamper-add. Every request and every tampering is logged to stderr.
import http from 'node:http';

function arg(flag, def) { const i = process.argv.indexOf(flag); return i === -1 ? def : process.argv[i + 1]; }
const listen = Number(arg('--listen', '8546'));
const upstream = arg('--upstream', 'http://127.0.0.1:8545');
const tSel = arg('--tamper-selector', null)?.toLowerCase() ?? null;
const tTo = arg('--tamper-to', null)?.toLowerCase() ?? null;
const tAdd = BigInt(arg('--tamper-add', '0'));
if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(upstream)) { console.error('refusing: upstream must be local'); process.exit(2); }

let tampered = 0;
function maybeTamper(req, res) {
  if (!tSel || req.method !== 'eth_call' || !res || typeof res.result !== 'string') return res;
  const call = req.params?.[0] ?? {};
  const data = (call.data ?? call.input ?? '').toLowerCase();
  if ((tTo && (call.to ?? '').toLowerCase() !== tTo) || !data.startsWith(tSel) || res.result.length !== 66) return res;
  const v = BigInt(res.result) + tAdd;
  tampered++;
  console.error(`[rpc-proxy] TAMPER #${tampered} ${call.to} ${data.slice(0, 10)} ${BigInt(res.result)} -> ${v}`);
  return { ...res, result: '0x' + v.toString(16).padStart(64, '0') };
}

http.createServer(async (inReq, inRes) => {
  let body = '';
  for await (const c of inReq) body += c;
  try {
    const r = await fetch(upstream, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
    const parsed = JSON.parse(body);
    let out = await r.json();
    out = Array.isArray(parsed) ? out.map((o, i) => maybeTamper(parsed[i], o)) : maybeTamper(parsed, out);
    inRes.writeHead(200, { 'content-type': 'application/json' });
    inRes.end(JSON.stringify(out));
  } catch (e) {
    inRes.writeHead(502); inRes.end(String(e));
  }
}).listen(listen, '127.0.0.1', () => console.error(`[rpc-proxy] 127.0.0.1:${listen} -> ${upstream}${tSel ? ` (TAMPER ${tTo} ${tSel} +${tAdd})` : ' (pass-through)'}`));
