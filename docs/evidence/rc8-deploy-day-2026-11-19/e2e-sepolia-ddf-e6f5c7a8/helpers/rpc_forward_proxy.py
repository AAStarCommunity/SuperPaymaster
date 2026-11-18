#!/usr/bin/env python3
# usage: rpc_forward_proxy.py LISTEN_PORT URL_FILE [ERRLOG]
# Local JSON-RPC forwarder so anvil's --fork-url is a loopback address: the upstream URL is read from
# URL_FILE inside this process and never appears in any argv, log or response. Upstream HTTP errors are
# passed through (status + body); transport errors are retried and logged by exception class only.
import http.server, socketserver, sys, time, urllib.error, urllib.request
PORT, URL = int(sys.argv[1]), open(sys.argv[2]).read().strip()
ERRLOG = sys.argv[3] if len(sys.argv) > 3 else None
def log(msg):
    if ERRLOG:
        with open(ERRLOG, "a") as f: f.write(time.strftime("%H:%M:%S ") + msg + "\n")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        data, code = None, 502
        for attempt in range(5):
            try:
                req = urllib.request.Request(URL, body, {"content-type": "application/json", "user-agent": "rehearsal-proxy/1"})
                with urllib.request.urlopen(req, timeout=120) as r:
                    data, code = r.read(), r.status
                break
            except urllib.error.HTTPError as e:
                data, code = e.read(), e.code; log(f"HTTPError {e.code} attempt {attempt}")
                if e.code not in (429, 502, 503, 504): break
            except Exception as e:
                log(f"{type(e).__name__} attempt {attempt}")
            time.sleep(0.5 * (attempt + 1))
        if data is None:
            data = b'{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"upstream error (redacted)"}}'
        self.send_response(code); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", PORT), H).serve_forever()
