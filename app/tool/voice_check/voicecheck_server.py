#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Serve the voice-check files to the emulator and take its WAVs back.
GET /list.txt -> every file under <root> (relative paths); GET /<path> -> the file;
PUT /out/<name> -> saved under <root>/../voicecheck-out/<name>.
Usage: voicecheck_server.py <root> <port>"""
import http.server, os, sys
root, port = sys.argv[1], int(sys.argv[2])
out = os.path.join(os.path.dirname(os.path.abspath(root)), "voicecheck-out")
os.makedirs(out, exist_ok=True)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/list.txt":
            files = []
            for d, _, fs in os.walk(root):
                for f in fs:
                    files.append(os.path.relpath(os.path.join(d, f), root))
            body = "\n".join(sorted(files)).encode()
        else:
            p = os.path.abspath(os.path.join(root, self.path.lstrip("/")))
            if not p.startswith(os.path.abspath(root)) or not os.path.isfile(p):
                self.send_error(404); return
            body = open(p, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_PUT(self):
        name = os.path.basename(self.path)
        n = int(self.headers["Content-Length"])
        data = self.rfile.read(n)
        if name.endswith(".log"):
            open(os.path.join(out, name), "ab").write(data)
        else:
            open(os.path.join(out, name), "wb").write(data)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
