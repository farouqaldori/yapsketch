# Serves website/ on http://127.0.0.1:4321, never cached, so edits show on reload.
cd website && exec python3 - <<'PY'
import http.server

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", 4321), NoCache).serve_forever()
PY
