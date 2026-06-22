#!/usr/bin/env python3
"""
Auto Company — Python AI Engine with Tool Execution (Claude Code v2 replacement)

Multi-turn AI agent with Read/Write/Bash tools.
Calls SenseNova API directly (or any Anthropic-compatible endpoint).

Usage:
    engine.py -p "task description" --output-format json --model deepseek-v4-flash

Env vars:
    ANTHROPIC_AUTH_TOKEN  — API key (Bearer auth to SenseNova)
    ANTHROPIC_BASE_URL    — API base URL (default: https://token.sensenova.cn)
"""
import argparse, os, json, urllib.request, urllib.error, ssl, sys, time, subprocess, shlex, re

# ── Proxy bypass ─────────────────────────────────────
for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy", "no_proxy", "NO_PROXY"):
    os.environ.pop(_k, None)
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

# ── Config ──────────────────────────────────────────
API_BASE = os.environ.get("ANTHROPIC_BASE_URL", "https://token.sensenova.cn").rstrip("/")
API_KEY = os.environ.get("ANTHROPIC_AUTH_TOKEN", os.environ.get("ANTHROPIC_API_KEY", ""))
API_URL = f"{API_BASE}/v1/messages"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOWED_BASE = PROJECT_ROOT  # Sandbox: only allow reads/writes under project root
MAX_TOOL_OUTPUT = 4000       # Truncate tool output
MAX_TURNS = 20               # Max API calls per session

_CTX = ssl.create_default_context()

# ── System Prompt ───────────────────────────────────
SYSTEM_PROMPT = f"""You are the **Coder** agent in Auto Company, an autonomous code improvement system.

## Your Role
Execute the task given in the user's prompt. You have access to tools: Read, Write, Bash.
Use them to read code, run commands, and write changes.

## Tool Call Format
To use a tool, output ONLY a JSON object with a "tool" field:

{{"tool": "Read", "path": "path/to/file"}}

{{"tool": "Write", "path": "path/to/file", "content": "file content"}}

{{"tool": "Bash", "command": "shell command"}}

The tool result will be returned as the next user message. You can chain multiple tools.

## Rules
- Project root: {PROJECT_ROOT} — all file paths are relative to this
- ONE tool per response — wait for the result before calling another
- Write tool REPLACES the entire file — include ALL content
- Keep Bash commands safe: no rm -rf, no sudo
- Read paths returned as actual content, Write returns "Written N bytes"

## Final Response
When the task is COMPLETE, output:

{{"result": "what you did", "confidence": 0.0-1.0, "needs_human": false}}

If you CANNOT complete: {{"result": "reason", "confidence": 0.0, "needs_human": true}}

## Critical
- NEVER output markdown or explanations outside the JSON
- NEVER use code fences (```)
- ALWAYS output valid JSON
- ALWAYS start with a Read tool to understand the code before editing
- You have limited turns — use them efficiently
- If you estimate the task needs more than 15 steps, break it into subtasks: complete the first chunk and output a partial result explaining what's done and what remains
- When you have read enough context, act decisively — don't re-read the same files"""


# ── Tool implementations ────────────────────────────

def tool_read(path: str) -> str:
    """Read a file under the project root."""
    full = os.path.normpath(os.path.join(ALLOWED_BASE, path))
    if not full.startswith(os.path.normpath(ALLOWED_BASE)):
        return f"ERROR: path {path} is outside project root"
    try:
        with open(full) as f:
            content = f.read()
        if len(content) > MAX_TOOL_OUTPUT * 2:
            content = content[:MAX_TOOL_OUTPUT] + f"\n... [truncated, {len(content)} total chars]"
        return content
    except FileNotFoundError:
        return f"ERROR: file not found: {path}"
    except Exception as e:
        return f"ERROR: {e}"


def tool_write(path: str, content: str) -> str:
    """Write a file under the project root."""
    full = os.path.normpath(os.path.join(ALLOWED_BASE, path))
    if not full.startswith(os.path.normpath(ALLOWED_BASE)):
        return f"ERROR: path {path} is outside project root"
    try:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(content)
        return f"Written {len(content)} bytes to {path}"
    except Exception as e:
        return f"ERROR: {e}"


def tool_bash(command: str) -> str:
    """Execute a shell command (sandboxed)."""
    blocked = ("rm -rf", "sudo", "> /dev/", "mkfs", "dd if=", ":(){ :|:& };:")
    cmd_lower = command.lower()
    for b in blocked:
        if b in cmd_lower:
            return f"ERROR: blocked command pattern: {b}"
    
    try:
        r = subprocess.run(
            command, shell=True, capture_output=True, text=True,
            timeout=30, cwd=ALLOWED_BASE,
            env={**os.environ, "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin")}
        )
        out = r.stdout + r.stderr
        if len(out) > MAX_TOOL_OUTPUT:
            out = out[:MAX_TOOL_OUTPUT] + f"\n... [truncated, exit={r.returncode}]"
        return out.strip() or f"(exit {r.returncode})"
    except subprocess.TimeoutExpired:
        return "ERROR: command timed out (30s)"
    except Exception as e:
        return f"ERROR: {e}"


TOOLS = {"Read": tool_read, "Write": tool_write, "Bash": tool_bash}

# ── API call ────────────────────────────────────────

def api_call(model: str, messages: list, max_tokens: int = 8000):
    """Call SenseNova /v1/messages."""
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
        "system": SYSTEM_PROMPT,
    }
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
        elapsed = (time.time() - start) * 1000
        result = json.loads(resp.read().decode())
        contents = result.get("content", [])
        text = "".join(c.get("text", c.get("thinking", "")) for c in contents)
        usage = result.get("usage", {})
        return {
            "success": True, "text": text,
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cost": (usage.get("input_tokens", 0) * 0.00028 + usage.get("output_tokens", 0) * 0.0011) / 1000,
            "elapsed_ms": elapsed,
            "http_status": None,
        }
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        return {"success": False, "text": "", "input_tokens": 0, "output_tokens": 0,
                "cost": 0, "elapsed_ms": (time.time() - start) * 1000,
                "http_status": e.code, "error": err_body[:500]}
    except Exception as e:
        return {"success": False, "text": "", "input_tokens": 0, "output_tokens": 0,
                "cost": 0, "elapsed_ms": (time.time() - start) * 1000,
                "http_status": 0, "error": str(e)}


def extract_json(text: str) -> dict | None:
    """Extract a JSON object from text (handles thinking + JSON mixed output)."""
    # Look for JSON object in the text
    text = text.strip()
    
    # Remove leading/trailing non-JSON content
    # Find first { and last }
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        return None
    
    candidate = text[start:end + 1]
    try:
        return json.loads(candidate)
    except json.JSONDecodeError:
        pass
    
    # Try extracting from common patterns
    for pattern in [r'\{[^{}]*"tool"[^{}]*\}', r'\{[^{}]*"result"[^{}]*\}']:
        m = re.search(pattern, text, re.DOTALL)
        if m:
            try:
                return json.loads(m.group())
            except:
                continue
    
    return None


# ── Main loop ───────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--prompt", type=str, default="")
    parser.add_argument("--output-format", type=str, default="json")
    parser.add_argument("--model", type=str, default="deepseek-v4-flash")
    parser.add_argument("--max-turns", type=int, default=MAX_TURNS)
    parser.add_argument("--permission-mode", type=str, default="bypassPermissions")
    parser.add_argument("--max-tokens", type=int, default=8000)
    args = parser.parse_args()

    prompt = args.prompt or sys.stdin.read().strip()
    if not prompt:
        print(json.dumps({"type": "result", "subtype": "success", "is_error": True,
                          "api_error_status": None, "result": "No prompt provided",
                          "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0, "num_turns": 0}))
        return 1

    if not API_KEY:
        print(json.dumps({"type": "result", "subtype": "error", "is_error": True,
                          "api_error_status": 401,
                          "result": "No API key configured",
                          "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0, "num_turns": 0}))
        return 2

    messages = [{"role": "user", "content": prompt}]
    total_start = time.time()
    total_cost = 0.0
    total_input = 0
    total_output = 0
    total_api_ms = 0
    api_turns = 0
    final_result = ""
    is_error = False
    api_status = None

    for turn in range(args.max_turns):
        api_turns = turn + 1
        resp = api_call(args.model, messages, args.max_tokens)
        total_api_ms += resp["elapsed_ms"]

        if not resp["success"]:
            api_status = resp.get("http_status", 0)
            is_error = True
            final_result = f"API error (HTTP {api_status}): {resp.get('error', 'unknown')[:200]}"
            break

        total_cost += resp["cost"]
        total_input += resp["input_tokens"]
        total_output += resp["output_tokens"]
        ai_text = resp["text"].strip()

        # Try to parse JSON from AI response
        parsed = extract_json(ai_text)

        if parsed is None:
            # AI didn't return valid JSON — treat as text response
            final_result = ai_text[:2000]
            # Check if it looks like a completion message
            if "complete" in ai_text.lower() or "done" in ai_text.lower():
                break
            # Otherwise ask AI to use proper format
            messages.append({"role": "assistant", "content": ai_text})
            messages.append({"role": "user", "content": "Please respond with a valid JSON tool call or final result. "
                             f"Use one of: {json.dumps(list(TOOLS.keys()))} or final format."})
            continue

        if "tool" in parsed:
            # Tool call
            tool_name = parsed["tool"]
            if tool_name not in TOOLS:
                messages.append({"role": "assistant", "content": json.dumps(parsed)})
                messages.append({"role": "user", "content": f"Unknown tool '{tool_name}'. Available: {list(TOOLS.keys())}"})
                continue

            # Execute tool
            if tool_name == "Read":
                result = tool_read(parsed.get("path", ""))
            elif tool_name == "Write":
                result = tool_write(parsed.get("path", ""), parsed.get("content", ""))
            elif tool_name == "Bash":
                result = tool_bash(parsed.get("command", ""))

            # Send result back to AI
            messages.append({"role": "assistant", "content": json.dumps(parsed)})
            messages.append({"role": "user", "content": f"Tool {tool_name} result:\n{result}"})
            continue

        elif "result" in parsed:
            # Final response
            final_result = parsed.get("result", "")
            break

        else:
            # Unknown JSON format
            final_result = json.dumps(parsed)[:2000]
            break

    else:
        # Max turns exceeded
        final_result = f"Max turns ({args.max_turns}) exceeded without task completion"
        is_error = True

    total_elapsed = (time.time() - total_start) * 1000

    output = {
        "type": "result",
        "subtype": "success" if not is_error else "error",
        "is_error": is_error,
        "api_error_status": api_status,
        "result": final_result,
        "total_cost_usd": round(total_cost, 8),
        "duration_ms": int(total_elapsed),
        "duration_api_ms": int(total_api_ms),
        "num_turns": api_turns,
        "usage": {"input_tokens": total_input, "output_tokens": total_output},
    }

    if args.output_format == "json":
        print(json.dumps(output))
    else:
        print(final_result)

    return 1 if is_error else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        output = {
            "type": "result", "subtype": "error", "is_error": True,
            "api_error_status": None,
            "result": f"Engine crash: {str(e)}",
            "total_cost_usd": 0, "duration_ms": 0, "duration_api_ms": 0, "num_turns": 0,
        }
        try:
            print(json.dumps(output))
        except:
            print(json.dumps({"type": "result", "is_error": True, "result": "Fatal engine error"}))
        sys.exit(1)
