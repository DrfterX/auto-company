#!/usr/bin/env python3
"""
Auto Company Protocol Translation Proxy v5
============================================
Receives Anthropic /v1/messages from Claude CLI,
translates to OpenAI /v1/chat/completions for DeepSeek/SenseNova,
translates response back to Anthropic format.

Key management is handled by auto-loop.sh — the proxy simply
uses whichever key is set in ANTHROPIC_AUTH_TOKEN.
No internal key rotation. No state.

Supports tool_use/tool_result ↔ function_call/tool bidirectional translation.
"""

import sys, json, time, os, http.server
import urllib.request, urllib.error

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082

# ── API Keys (for health endpoint count only) ─────────────────────────────────
API_KEYS = [k for k in [
    os.environ.get("AC_API_KEY_1", ""),
    os.environ.get("AC_API_KEY_2", ""),
    os.environ.get("AC_API_KEY_3", ""),
    os.environ.get("AC_API_KEY_4", ""),
    os.environ.get("AC_API_KEY_5", ""),
    os.environ.get("AC_API_KEY_6", ""),
] if k]

# DeepSeek speaks OpenAI protocol only → send to /v1/chat/completions
BACKEND_URL = "https://token.sensenova.cn/v1/chat/completions"
MODEL = "deepseek-v4-flash"

# ── Protocol Translation ──────────────────────────────────────────────────────

def anthropic_to_openai(body):
    """Anthropic /v1/messages → OpenAI /v1/chat/completions"""
    system = body.get("system", "")
    messages = body.get("messages", [])
    tools = body.get("tools", [])
    max_tokens = body.get("max_tokens", 4096)

    oa_msgs = []

    # 1. System message
    if system:
        if isinstance(system, list):
            system = "\n".join(x.get("text", "") for x in system if isinstance(x, dict))
        oa_msgs.append({"role": "system", "content": system})

    # 2. Convert messages
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")

        if role == "assistant":
            text_parts = []
            tool_calls = []

            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    t = block.get("type", "")
                    if t == "text":
                        text_parts.append(block.get("text", ""))
                    elif t == "tool_use":
                        tc = {
                            "id": block.get("id", ""),
                            "type": "function",
                            "function": {
                                "name": block.get("name", ""),
                                "arguments": json.dumps(block.get("input", {}), ensure_ascii=False),
                            }
                        }
                        tool_calls.append(tc)

            oa_msg = {"role": "assistant", "content": "\n".join(text_parts) or None}
            if tool_calls:
                oa_msg["tool_calls"] = tool_calls
            oa_msgs.append(oa_msg)

        elif role == "user":
            if isinstance(content, list):
                text_parts = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        tool_use_id = block.get("tool_use_id", "")
                        result_content = block.get("content", "")
                        if isinstance(result_content, list):
                            result_content = "\n".join(
                                x.get("text", "") for x in result_content
                                if isinstance(x, dict)
                            )
                        oa_msgs.append({
                            "role": "tool",
                            "tool_call_id": tool_use_id,
                            "content": str(result_content),
                        })
                    elif isinstance(block, dict) and block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
                if text_parts:
                    oa_msgs.append({"role": "user", "content": "\n".join(text_parts)})
            else:
                oa_msgs.append({"role": "user", "content": str(content)})

    # 3. Tools
    oa_tools = []
    for t in tools:
        oa_tools.append({
            "type": "function",
            "function": {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {}),
            }
        })

    payload = {
        "model": MODEL,
        "messages": oa_msgs,
        "max_tokens": max_tokens,
        "stream": body.get("stream", False),
        "temperature": body.get("temperature", 0.7),
    }
    if body.get("top_p"):
        payload["top_p"] = body["top_p"]
    if oa_tools:
        payload["tools"] = oa_tools

    return payload


def openai_to_anthropic(oa_resp, max_tokens=4096):
    """OpenAI /v1/chat/completions response → Anthropic /v1/messages response"""
    choices = oa_resp.get("choices", [])
    if not choices:
        return {"type": "message", "role": "assistant", "content": [{"type": "text", "text": ""}]}

    msg = choices[0].get("message", {})
    content_text = msg.get("content", "") or ""
    tool_calls = msg.get("tool_calls", [])

    content_blocks = []

    if content_text:
        content_blocks.append({"type": "text", "text": content_text})

    for tc in tool_calls:
        if tc.get("type") == "function":
            fn = tc.get("function", {})
            try:
                arguments = json.loads(fn.get("arguments", "{}"))
            except (json.JSONDecodeError, TypeError):
                arguments = {}
            content_blocks.append({
                "type": "tool_use",
                "id": tc.get("id", ""),
                "name": fn.get("name", ""),
                "input": arguments,
            })

    stop_reason = choices[0].get("finish_reason", "end_turn")
    sr_map = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use"}
    anthropic_reason = sr_map.get(stop_reason, "end_turn")

    usage = oa_resp.get("usage", {})
    anthropic_usage = {}
    if usage:
        anthropic_usage = {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        }

    return {
        "type": "message",
        "role": "assistant",
        "content": content_blocks,
        "stop_reason": anthropic_reason,
        "stop_sequence": None,
        "usage": anthropic_usage,
        "model": MODEL,
    }


# ── HTTP Handler ──────────────────────────────────────────────────────────────
class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
        self.end_headers()
        if body:
            self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-api-key, anthropic-version")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {
                "status": "ok",
                "mode": "anthropic-openai-translate",
                "keys": len(API_KEYS),
                "model": MODEL,
                "backend": BACKEND_URL,
            })
        elif self.path in ("/models", "/v1/models"):
            claude_models = [
                "claude-opus-4-8", "claude-opus-4-8-20250514",
                "claude-sonnet-4-6", "claude-sonnet-4-6-20250507",
                "claude-sonnet-4-20250507", "claude-haiku-3-5-20241022",
                "claude-3-5-haiku-latest", "claude-3-5-sonnet-latest",
                "claude-opus-4-latest", "claude-sonnet-4-latest",
            ]
            self._send(200, {"data": [{"id": m, "object": "model", "created": int(time.time()), "owned_by": "sensenova"} for m in claude_models]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/v1/messages"):
            self._send(404, {"error": f"not found: {self.path}"})
            return

        # Read request body
        try:
            length = int(self.headers.get("Content-Length", 0))
            anth_body = json.loads(self.rfile.read(length))
        except Exception as e:
            self._send(400, {"error": f"bad request: {e}"})
            return

        # Translate: Anthropic → OpenAI
        try:
            oa_body = anthropic_to_openai(anth_body)
        except Exception as e:
            self._send(500, {"error": f"translation error: {e}"})
            return

        oa_body["stream"] = False

        # ── Use the key that auto-loop.sh chose ──
        key = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
        if not key:
            self._send(500, {"error": "no API key configured (ANTHROPIC_AUTH_TOKEN not set)"})
            return

        t0 = time.time()

        try:
            req_body = json.dumps(oa_body).encode()
            req = urllib.request.Request(
                BACKEND_URL,
                data=req_body,
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json",
                },
            )
            resp = urllib.request.urlopen(req, timeout=120)
            oa_result = json.loads(resp.read())
            elapsed = int((time.time() - t0) * 1000)

            anth_result = openai_to_anthropic(oa_result, anth_body.get("max_tokens", 4096))

            usage = oa_result.get("usage", {})
            total_tokens = usage.get("total_tokens", 0)
            print(f"[{time.strftime('%H:%M:%S')}] {elapsed}ms {total_tokens}t | tools={bool(oa_body.get('tools'))}", flush=True)

            self._send(200, anth_result)
            return

        except urllib.error.HTTPError as e:
            err_body = e.read().decode()
            elapsed = int((time.time() - t0) * 1000)
            print(f"[{time.strftime('%H:%M:%S')}] HTTP {e.code} {elapsed}ms", flush=True)
            self._send(e.code, json.loads(err_body) if err_body else {"error": f"HTTP {e.code}"})
            return

        except Exception as e:
            elapsed = int((time.time() - t0) * 1000)
            print(f"[{time.strftime('%H:%M:%S')}] ERR {elapsed}ms {type(e).__name__}: {e}", flush=True)
            self._send(502, {"error": str(e)})
            return


if __name__ == "__main__":
    if not API_KEYS:
        print("ERROR: No API keys configured", flush=True)
        sys.exit(1)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), ProxyHandler)
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Auto Company Proxy v5 (Anthropic↔OpenAI | passive)", flush=True)
    print(f"  Port:    {PORT}", flush=True)
    print(f"  Keys:    {len(API_KEYS)}", flush=True)
    print(f"  Model:   {MODEL}", flush=True)
    print(f"  Backend: {BACKEND_URL}", flush=True)
    server.serve_forever()
