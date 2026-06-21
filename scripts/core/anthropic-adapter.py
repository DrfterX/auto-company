#!/usr/bin/env python3
"""
Auto Company — mini Anthropic protocol adapter
Maps Claude CLI's messages[] with role=system -> top-level "system" param.
Listen on localhost:8082, forward to https://token.sensenova.cn/v1/messages
"""
import json, http.server, urllib.request, urllib.error
import ssl
import threading

BACKEND = "https://token.sensenova.cn/v1/messages"
PORT = 8082
_CTX = ssl.create_default_context()

class Handler(http.server.BaseHTTPRequestHandler):
    # Suppress default stderr logging
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            req = json.loads(body)

            # Move messages with role=system to top-level system parameter
            msgs = req.get("messages", [])
            system_parts = [m["content"] for m in msgs if m.get("role") == "system"]
            req["messages"] = [m for m in msgs if m.get("role") != "system"]
            if system_parts:
                combined = "\n\n".join(system_parts)
                if isinstance(req.get("system"), str):
                    req["system"] = req["system"] + "\n\n" + combined
                else:
                    req["system"] = combined

            # Forward to SenseNova (only Content-Type + Auth, no proxy headers)
            api_key = self.headers.get("x-api-key", "") or self.headers.get("Authorization", "") or ""
            data = json.dumps(req).encode()
            fwd_req = urllib.request.Request(
                BACKEND, data=data,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": api_key,
                    "Accept": "application/json",
                    "anthropic-version": "2023-06-01",
                },
                method="POST"
            )
            try:
                resp = urllib.request.urlopen(fwd_req, timeout=600, context=_CTX)
                body_bytes = resp.read()
                # Send clean response — only forward Content-Type
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body_bytes)))
                self.end_headers()
                self.wfile.write(body_bytes)
            except urllib.error.HTTPError as e:
                err_body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err_body)))
                self.end_headers()
                self.wfile.write(err_body)
            except Exception as e:
                # Catch any other upstream error (timeout, DNS, connection reset)
                err_msg = json.dumps({"error": str(e)}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err_msg)))
                self.end_headers()
                self.wfile.write(err_msg)
        except Exception:
            # Catch-all: prevent any crash from killing the server
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"bad_request"}')

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "15")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Mini adapter listening on :{PORT}")
    server.serve_forever()
