#!/usr/bin/env python3
"""
Auto Company — Python AI Engine (Claude Code v2 replacement)

Drop-in replacement for `claude -p "..." --output-format json`.
Calls SenseNova API directly (or any Anthropic-compatible endpoint).
Outputs JSON compatible with auto-loop.sh's extract_cycle_metadata().

Usage:
    engine.py -p "say hi" --output-format json --model deepseek-v4-flash --max-turns 1

Env vars:
    ANTHROPIC_AUTH_TOKEN  — API key (Bearer auth to SenseNova)
    ANTHROPIC_BASE_URL    — API base URL (default: https://token.sensenova.cn)
"""
import argparse, os, json, urllib.request, urllib.error, ssl, sys, time, traceback

# ── Proxy bypass (system proxy interferes with direct SenseNova calls) ──
# Must be done at module level BEFORE any urllib calls
for _env_proxy_key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy", "no_proxy", "NO_PROXY"):
    os.environ.pop(_env_proxy_key, None)
proxy_handler = urllib.request.ProxyHandler({})
opener = urllib.request.build_opener(proxy_handler)
urllib.request.install_opener(opener)

# ── Config ──────────────────────────────────────────
API_BASE = os.environ.get("ANTHROPIC_BASE_URL", "https://token.sensenova.cn").rstrip("/")
API_KEY = os.environ.get("ANTHROPIC_AUTH_TOKEN", os.environ.get("ANTHROPIC_API_KEY", ""))
API_URL = f"{API_BASE}/v1/messages"
SYSTEM_PROMPT = """You are an expert AI agent operating in auto-loop mode.

Output ONLY a valid JSON object with these fields:
- "result": your detailed analysis and action plan (string)
- "confidence": 0.0-1.0
- "needs_human": true/false

Do NOT output markdown. Do NOT output anything before or after the JSON."""

_CTX = ssl.create_default_context()


def api_call(model: str, messages: list, system: str, max_tokens: int = 8000, temperature: float = 0.0):
    """Call SenseNova /v1/messages (Anthropic-compatible)."""
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if system:
        body["system"] = system
    
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        API_URL, data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
            "Accept": "application/json",
        },
        method="POST"
    )
    
    start = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=600, context=_CTX)
        elapsed = (time.time() - start) * 1000  # ms
        result = json.loads(resp.read().decode())
        
        # Extract text content
        contents = result.get("content", [])
        text = ""
        thinking = ""
        for c in contents:
            if c.get("type") == "text":
                text += c.get("text", "")
            elif c.get("type") == "thinking":
                thinking = c.get("thinking", "")
        
        usage = result.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        
        # Rough cost estimate for DeepSeek v4
        cost = (input_tokens * 0.00028 + output_tokens * 0.0011) / 1000
        
        return {
            "success": True,
            "text": text or thinking,
            "thinking": thinking,
            "usage": usage,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost": cost,
            "elapsed_ms": elapsed,
            "stop_reason": result.get("stop_reason", "unknown"),
            "api_response": result,
        }
    except urllib.error.HTTPError as e:
        elapsed = (time.time() - start) * 1000
        err_body = e.read().decode()
        return {
            "success": False,
            "http_status": e.code,
            "error": err_body[:500],
            "elapsed_ms": elapsed,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost": 0,
        }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "success": False,
            "http_status": 0,
            "error": str(e),
            "elapsed_ms": elapsed,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost": 0,
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--prompt", type=str, default="", help="User prompt")
    parser.add_argument("--output-format", type=str, default="json")
    parser.add_argument("--model", type=str, default="deepseek-v4-flash")
    parser.add_argument("--max-turns", type=int, default=1)
    parser.add_argument("--permission-mode", type=str, default="bypassPermissions")
    parser.add_argument("--max-tokens", type=int, default=8000)
    args = parser.parse_args()
    
    prompt = args.prompt
    if not prompt:
        # Read from stdin
        prompt = sys.stdin.read().strip()
    
    if not prompt:
        print(json.dumps({
            "type": "result", "subtype": "success", "is_error": True,
            "api_error_status": None, "result": "No prompt provided",
            "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0,
            "num_turns": 0,
        }))
        return 1
    
    # Check API key
    if not API_KEY:
        result = {
            "type": "result", "subtype": "error", "is_error": True,
            "api_error_status": 401,
            "result": "No API key configured (ANTHROPIC_AUTH_TOKEN)",
            "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0,
            "num_turns": 0,
        }
        if args.output_format == "json":
            print(json.dumps(result))
        return 2
    
    # Make API call
    messages = [{"role": "user", "content": prompt}]
    total_start = time.time()
    
    result_text = ""
    total_cost = 0
    total_input = 0
    total_output = 0
    total_api_ms = 0
    api_status = None
    is_error = False
    
    for turn in range(args.max_turns):
        resp = api_call(args.model, messages, SYSTEM_PROMPT)
        total_api_ms += resp["elapsed_ms"]
        
        if not resp["success"]:
            api_status = resp.get("http_status", 0)
            is_error = True
            result_text = f"API error: {resp.get('error', 'unknown')}"
            break
        
        result_text = resp["text"]
        total_cost += resp["cost"]
        total_input += resp["input_tokens"]
        total_output += resp["output_tokens"]
        
        # For single-turn, we're done
        if args.max_turns == 1:
            break
        
        # Multi-turn: add assistant response and continue
        messages.append({"role": "assistant", "content": result_text})
    
    total_elapsed = (time.time() - total_start) * 1000
    
    # Build auto-loop compatible output
    output = {
        "type": "result",
        "subtype": "success" if not is_error else "error",
        "is_error": is_error,
        "api_error_status": api_status,
        "result": result_text,
        "total_cost_usd": round(total_cost, 8),
        "duration_ms": int(total_elapsed),
        "duration_api_ms": int(total_api_ms),
        "num_turns": args.max_turns,
        "usage": {
            "input_tokens": total_input,
            "output_tokens": total_output,
        },
    }
    
    if args.output_format == "json":
        print(json.dumps(output))
    else:
        print(result_text)
    
    return 1 if is_error else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        output = {
            "type": "result", "subtype": "error", "is_error": True,
            "api_error_status": None,
            "result": f"Engine crash: {str(e)}",
            "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0,
            "num_turns": 0,
        }
        try:
            print(json.dumps(output))
        except:
            print(json.dumps({"type":"result","is_error":True,"result":"Fatal engine error"}))
        sys.exit(1)
