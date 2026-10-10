#!/usr/bin/env python3
"""SELF-TEST ONLY. JSON-RPC pass-through used as endpoint B of scripts/a2-row0-7b-debt-scan.py to prove the scan
is fail-closed against a lying endpoint. Read-only: forwards requests unchanged to a keyless upstream; holds no key.

  python3 scripts/a2-debt-scan-tamper-proxy.py <port> <upstreamUrl> <mode>
  mode: pass                 forward unchanged (control)
        empty-once:<selector> answer "0x" (instead of the real 32-byte word) to the FIRST plain eth_call
                              (no state override) whose calldata starts with <selector>; everything else unchanged
Each tampering is printed to stdout.
"""
import json, sys, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, upstream, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
assert mode == 'pass' or mode.startswith('empty-once:0x'), 'bad mode'
SELECTOR = mode.split(':', 1)[1].lower() if mode != 'pass' else None
state = {'done': False}


def tamper(req, res):
    if SELECTOR is None or state['done'] or req.get('method') != 'eth_call':
        return res
    params = req.get('params') or []
    if len(params) > 2 or not params or not str(params[0].get('data', '')).lower().startswith(SELECTOR):
        return res
    if 'result' in res:
        state['done'] = True
        print('TAMPER eth_call data=%s… real=%s -> "0x"' % (params[0]['data'][:74], res['result']), flush=True)
        res = dict(res, result='0x')
    return res


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers['content-length']))
        up = urllib.request.Request(upstream, data=body, headers={'content-type': 'application/json',
                                                                  'user-agent': 'a2-tamper-proxy/1'})
        try:
            out = json.load(urllib.request.urlopen(up, timeout=180))
        except urllib.error.HTTPError as e:
            self.send_response(e.code); self.end_headers(); self.wfile.write(e.read()); return
        req = json.loads(body)
        out = [tamper(q, r) for q, r in zip(req, out)] if isinstance(out, list) else tamper(req, out)
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
