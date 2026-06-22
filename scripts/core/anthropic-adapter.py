#!/usr/bin/env python3
"""
Auto Company — Anthropic ↔ SenseNova protocol adapter (v2)
Complete adapter for Claude Code >= 2.x

Features:
- POST /v1/messages → SenseNova /v1/messages (Anthropic-compatible)
- GET /v1/models → Return supported model list
- Strips streaming (SenseNova doesn't support SSE for Anthropic endpoint)
- Proper error forwarding with Anthropic-format error responses
- Health check at GET /health
- Request logging to stderr for debugging
"""
import json, http.server, urllib.request, urllib.error, ssl, threading, os, sys, time

BACKEND_MESSAGES = "https://token.sensenova.cn/v1/messages"
PORT = 8082

# Models supported by SenseNova's DeepSeek implementation
MODELS = [
    {"id": "deepseek-v4-flash", "object": "model", "created": 1, "owned_by": "sensenova"},
    {"id": "deepseek-v4-pro", "object": "model", "created": 1, "owned_by": "sensenova"},
]

_CTX = ssl.create_default_context()
_DEBUG = os.environ.get("ADAPTER_DEBUG", "0") == "1"

def log(msg):
    """Log to stderr for operational visibility."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[adapter {ts}] {msg}", file=sys.stderr, flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _get_auth(self):
        """Extract auth from x-api-key or Authorization header."""
        raw = self.headers.get("x-api-key", "") or self.headers.get("Authorization", "")
        return raw

    def do_GET(self):
        body = b""
        status = 200
        if self.path == "/health":
            body = b'{"status":"ok"}'
        elif self.path == "/v1/models" or self.path == "/v1/models/":
            body = json.dumps({"object": "list", "data": MODELS}).encode()
        else:
            status = 404
            body = b'{"error":"not_found"}'
        
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        # CORS preflight
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-api-key, anthropic-version")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            req = json.loads(body)

            # ── Anthropic → SenseNova request transformation ──

            # 1. Move messages with role=system → top-level system param
            msgs = req.get("messages", [])
            system_parts = [m.get("content", "") for m in msgs if m.get("role") == "system"]
            req["messages"] = [m for m in msgs if m.get("role") != "system"]
            if system_parts:
                combined = "\n\n".join(system_parts)
                existing = req.get("system", "")
                if existing:
                    combined = existing + "\n\n" + combined
                req["system"] = combined

            # 2. Strip streaming — SenseNova Anthropic endpoint doesn't support SSE
            is_stream = req.get("stream", False)
            if is_stream:
                if _DEBUG:
                    log("Stripping stream=true from request")
                req["stream"] = False

            # 3. Get auth (Claude Code sends x-api-key)
            api_key = self._get_auth()

            if _DEBUG:
                # Log request (redacted)
                safe_req = {}
                for k, v in req.items():
                    if k == "messages":
                        safe_req[k] = f"[{len(v)} messages]"
                    elif k == "system":
                        safe_req[k] = str(v)[:80]
                    else:
                        safe_req[k] = v
                log(f"POST /v1/messages stream={is_stream} model={req.get('model','?')} auth={api_key[:12]}... body={json.dumps(safe_req)[:200]}")

            # 4. Forward to SenseNova
            data = json.dumps(req).encode()
            fwd_req = urllib.request.Request(
                BACKEND_MESSAGES, data=data,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": api_key,
                    "Accept": "application/json",
                },
                method="POST"
            )

            try:
                resp = urllib.request.urlopen(fwd_req, timeout=600, context=_CTX)
                body_bytes = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body_bytes)))
                self.end_headers()
                self.wfile.write(body_bytes)
            except urllib.error.HTTPError as e:
                err_body = e.read()
                if _DEBUG:
                    log(f"Upstream HTTP {e.code}: {err_body[:200]}")
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err_body)))
                self.end_headers()
                self.wfile.write(err_body)
            except Exception as e:
                # Catch any other upstream error
                err_msg = json.dumps({
                    "type": "error",
                    "error": {"type": "api_error", "message": str(e)}
                }).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err_msg)))
                self.end_headers()
                self.wfile.write(err_msg)
        except Exception as e:
            # Catch-all: prevent any crash from killing the server
            if _DEBUG:
                log(f"Handler exception: {e}")
            err = json.dumps({
                "type": "error",
                "error": {"type": "invalid_request_error", "message": str(e)}
            }).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)


if __name__ == "__main__":
    # Clean up any stale process on our port
    import subprocess
    r = subprocess.run(["lsof", "-t", f"-i:{PORT}"], capture_output=True, text=True)
    for pid in r.stdout.strip().split():
        try:
            os.kill(int(pid), 9)
            log(f"Killed stale adapter on port {PORT} (PID {pid})")
        except:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log(f"Listening on :{PORT} → {BACKEND_MESSAGES}")
    server.serve_forever()
