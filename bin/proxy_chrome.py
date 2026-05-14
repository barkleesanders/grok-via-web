#!/usr/bin/env python3
"""
grok.com → OpenAI-compatible proxy, via Chrome UI + CDP Network capture.

For each /v1/chat/completions request:
  1. Submit the user's prompt through the real grok.com web UI (in your
     already-signed-in Chrome at --remote-debugging-port=9222).
  2. Capture the response body of POST /rest/app-chat/conversations/new
     via CDP's Network domain — this is the same NDJSON stream the SPA
     consumes, with all Statsig/Cloudflare bot checks passed because the
     request was issued by the legit app.
  3. Parse the NDJSON and return the assembled assistant message as an
     OpenAI-compatible completion.

Usage:
    python3 proxy_chrome.py [--port 8788] [--cdp 9222]

    export GROK_MODELS_BASE_URL=http://localhost:8788/v1
    export GROK_CODE_XAI_API_KEY=anything-non-empty
    grok -p "say hi"
"""
from __future__ import annotations

import argparse, asyncio, json, logging, sys, time, uuid
from urllib.request import urlopen, Request
from urllib.error import URLError
from aiohttp import web, ClientSession, WSMsgType

log = logging.getLogger("grok-proxy")

CHAT_PATH = "/rest/app-chat/conversations/new"
RESPONSE_TIMEOUT_S = 90


# ============================================================================
# CDP client
# ============================================================================

class CDPSession:
    """Minimal CDP client over a single WebSocket connection."""

    def __init__(self, ws_url: str):
        self.ws_url = ws_url
        self._ws = None
        self._http = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.event_queue: asyncio.Queue = asyncio.Queue()
        self._reader_task = None

    async def __aenter__(self):
        self._http = ClientSession()
        self._ws = await self._http.ws_connect(self.ws_url, max_msg_size=0,
                                                heartbeat=30)
        self._reader_task = asyncio.create_task(self._reader())
        return self

    async def __aexit__(self, *exc):
        if self._reader_task:
            self._reader_task.cancel()
        if self._ws:
            await self._ws.close()
        if self._http:
            await self._http.close()

    async def _reader(self):
        try:
            async for msg in self._ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                data = json.loads(msg.data)
                if "id" in data:
                    fut = self._pending.pop(data["id"], None)
                    if fut and not fut.done():
                        if "error" in data:
                            fut.set_exception(RuntimeError(str(data["error"])))
                        else:
                            fut.set_result(data.get("result", {}))
                elif "method" in data:
                    await self.event_queue.put(data)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            log.warning("CDP reader stopped: %s", e)

    async def send(self, method: str, params: dict | None = None,
                   timeout: float = 30.0) -> dict:
        self._next_id += 1
        msg_id = self._next_id
        msg = {"id": msg_id, "method": method}
        if params is not None:
            msg["params"] = params
        fut = asyncio.get_event_loop().create_future()
        self._pending[msg_id] = fut
        await self._ws.send_str(json.dumps(msg))
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(msg_id, None)
            raise

    async def eval(self, expr: str, await_promise: bool = True,
                   timeout: float = 30.0):
        r = await self.send("Runtime.evaluate", {
            "expression": expr,
            "awaitPromise": await_promise,
            "returnByValue": True,
        }, timeout=timeout)
        ex = r.get("exceptionDetails")
        if ex:
            raise RuntimeError(f"JS exception: {ex.get('text')}: "
                               f"{json.dumps(ex)[:300]}")
        return r.get("result", {}).get("value")


# ============================================================================
# Tab discovery
# ============================================================================

def list_tabs(cdp_port: int) -> list[dict]:
    try:
        with urlopen(f"http://localhost:{cdp_port}/json") as r:
            return json.loads(r.read())
    except URLError as e:
        raise RuntimeError(f"Chrome CDP at :{cdp_port} not reachable: {e}")


# Persistent tab id we created (so we reuse the same tab across requests)
_PROXY_TAB_ID: str | None = None
_PROXY_TAB_TITLE_MARK = "grok-proxy"


def find_grok_tab(cdp_port: int) -> dict:
    """Find or create a dedicated grok.com tab for the proxy.

    Strategy:
    1. If we've already created a tab in this process, reuse it.
    2. Otherwise, look for an existing tab whose title contains our marker
       (survives process restarts).
    3. Otherwise, look for any grok.com tab and adopt it.
    4. Otherwise, create a new tab.
    """
    global _PROXY_TAB_ID
    tabs = [t for t in list_tabs(cdp_port) if t.get("type") == "page"]

    # 1. Already-claimed tab from this run
    if _PROXY_TAB_ID:
        for t in tabs:
            if t.get("id") == _PROXY_TAB_ID:
                return t

    # 2. Re-adopt a previously-marked tab
    for t in tabs:
        if _PROXY_TAB_TITLE_MARK in (t.get("title") or "").lower():
            _PROXY_TAB_ID = t.get("id")
            return t

    # 3. Adopt any grok.com tab (prefer https://grok.com/ root)
    grok = [t for t in tabs if "grok.com" in t.get("url", "")]
    grok.sort(key=lambda t: 0 if t.get("url", "").rstrip("/") == "https://grok.com" else 1)
    if grok:
        _PROXY_TAB_ID = grok[0].get("id")
        return grok[0]

    # 4. Create a new tab
    req = Request(f"http://localhost:{cdp_port}/json/new?https://grok.com/",
                  method="PUT")
    with urlopen(req) as r:
        t = json.loads(r.read())
        _PROXY_TAB_ID = t.get("id")
        return t


# ============================================================================
# UI driver
# ============================================================================

SUBMIT_JS = r"""
(async () => {
  // Find the prompt input (contenteditable div with role=textbox or just CE)
  const inputs = [...document.querySelectorAll('[contenteditable="true"]')];
  if (!inputs.length) throw new Error("no contenteditable input found");
  const ta = inputs[inputs.length - 1];
  ta.focus();
  // Clear + insert via execCommand so React state updates
  document.execCommand('selectAll', false, null);
  document.execCommand('insertText', false, %PROMPT%);
  await new Promise(r => setTimeout(r, 300));

  // Find submit button — aria-label "Submit" is the canonical
  let btn = document.querySelector('button[aria-label="Submit"]');
  if (!btn) {
    btn = [...document.querySelectorAll('button')].find(b =>
      /^submit$/i.test((b.getAttribute('aria-label') || '').trim()));
  }
  if (!btn) {
    // Fallback: Enter keydown
    ta.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
    }));
    return { method: 'enter' };
  }
  if (btn.disabled) {
    await new Promise(r => setTimeout(r, 300));
  }
  btn.click();
  return { method: 'click' };
})()
"""


def js_string(s: str) -> str:
    return json.dumps(s)


async def ensure_fresh_chat(cdp: CDPSession):
    """Navigate to https://grok.com/ for a fresh chat.

    If the tab is already on the grok.com root, this is essentially a no-op
    (we still navigate to ensure the input is empty). Sets the marker title
    so a restarted proxy can re-adopt this tab.
    """
    await cdp.send("Page.navigate", {"url": "https://grok.com/"})
    # Wait for the input to be ready
    for _ in range(80):  # up to 20s
        try:
            ready = await cdp.eval(
                "!!document.querySelector('[contenteditable=\"true\"]')",
                await_promise=False, timeout=3)
            if ready:
                # Mark the tab so subsequent proxy runs find it
                try:
                    await cdp.eval(
                        f"document.title = 'grok.com — {_PROXY_TAB_TITLE_MARK}'",
                        await_promise=False, timeout=2)
                except Exception:
                    pass
                return
        except Exception:
            pass
        await asyncio.sleep(0.25)
    raise RuntimeError("grok.com input never became ready (20s timeout)")


async def submit_prompt(cdp: CDPSession, prompt: str):
    expr = SUBMIT_JS.replace("%PROMPT%", js_string(prompt))
    return await cdp.eval(expr, timeout=15)


# ============================================================================
# Network interception
# ============================================================================

async def capture_chat_response(cdp: CDPSession) -> str:
    """Wait for the chat-completion request to land, then return its body."""
    request_id = None
    deadline = asyncio.get_event_loop().time() + RESPONSE_TIMEOUT_S

    while asyncio.get_event_loop().time() < deadline:
        timeout = deadline - asyncio.get_event_loop().time()
        try:
            evt = await asyncio.wait_for(cdp.event_queue.get(),
                                          timeout=min(timeout, 5))
        except asyncio.TimeoutError:
            continue

        method = evt.get("method")
        params = evt.get("params", {})

        if method == "Network.requestWillBeSent":
            req = params.get("request", {})
            if CHAT_PATH in req.get("url", "") and \
               req.get("method") == "POST":
                request_id = params.get("requestId")
                log.info("captured chat request id=%s", request_id)

        elif method == "Network.loadingFinished" and request_id and \
             params.get("requestId") == request_id:
            log.info("loadingFinished id=%s — fetching body", request_id)
            # Give Chrome a moment to flush buffers
            await asyncio.sleep(0.3)
            r = await cdp.send("Network.getResponseBody",
                               {"requestId": request_id})
            body = r.get("body", "")
            if r.get("base64Encoded"):
                import base64
                body = base64.b64decode(body).decode("utf-8", errors="replace")
            return body

        elif method == "Network.loadingFailed" and request_id and \
             params.get("requestId") == request_id:
            err = params.get("errorText", "unknown")
            raise RuntimeError(f"chat request failed: {err}")

    raise TimeoutError(f"no chat response within {RESPONSE_TIMEOUT_S}s")


# ============================================================================
# NDJSON parsing (same shape as cookie-replay proxy)
# ============================================================================

class GrokError(Exception):
    """Surfaces grok.com server errors (rate limits, auth, etc) to the caller."""


def parse_chat_body(body: str) -> str:
    """Extract the final assembled assistant message text from grok.com's
    NDJSON stream.

    Raises GrokError if the body looks like an error JSON (single non-NDJSON
    object with `error` key, or contains a rate-limit indicator). This is the
    most common failure mode — quota exhausted at 25 queries/2h on free tier.
    """
    tokens = []
    final_msg = None
    error_msg = None

    # Common single-line error JSON: {"error":{"code":N,"message":"...","details":[]}}
    try:
        single = json.loads(body)
        if isinstance(single, dict) and "error" in single:
            err = single["error"]
            error_msg = err.get("message") or str(err)
    except (json.JSONDecodeError, ValueError):
        pass

    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        # NDJSON-formatted error frames
        if isinstance(ev, dict) and "error" in ev and "result" not in ev:
            err = ev["error"]
            error_msg = err.get("message") if isinstance(err, dict) else str(err)
            continue
        resp = ev.get("result", {}).get("response", {})
        if not resp:
            continue
        tag = resp.get("messageTag")
        tok = resp.get("token")
        is_thinking = resp.get("isThinking", False)
        if tok and tag == "final" and not is_thinking:
            tokens.append(tok)
        mr = resp.get("modelResponse")
        if mr:
            msg = mr.get("message", "")
            if msg:
                final_msg = msg

    if final_msg:
        return final_msg
    text = "".join(tokens)
    if text:
        return text
    # Nothing extracted — surface error if we saw one, else a clear "empty"
    # marker so the caller doesn't silently send "" back to the CLI.
    if error_msg:
        raise GrokError(error_msg)
    # Detect implicit rate-limit shape: empty body or near-empty NDJSON
    if len(body.strip()) < 50:
        raise GrokError(
            "grok.com returned an empty response. This usually means you've "
            "hit the free-tier rate limit (25 queries / 2h). Check "
            "https://grok.com/rest/rate-limits in your browser to see when it "
            "resets, or switch to a non-grok model via grok-litellm.")
    raise GrokError(f"grok.com response yielded no tokens (body len={len(body)})")


# ============================================================================
# Message flattening
# ============================================================================

def _text(c):
    if isinstance(c, list):
        return "".join(p.get("text", "") for p in c if p.get("type") == "text")
    return c or ""


import re

# Grok CLI wraps the human-typed query inside <user_query>...</user_query>
USER_QUERY_RE = re.compile(
    r"<user_query>\s*(.*?)\s*</user_query>", re.DOTALL | re.IGNORECASE)


def flatten(messages: list[dict]) -> str:
    """OpenAI messages → single grok.com prompt.

    The Grok CLI sends ~100KB of XML-tagged metadata per request:
        - 12KB system prompt
        - <user_info> shell/cwd context
        - <system-reminder> blocks listing available skills + MCP servers
        - The repo's AGENTS.md / Claude.md verbatim
        - And finally <user_query>...</user_query> with what the human typed

    If we forward all of that to grok.com, the web UI thinks the XML is a
    request to run its sitemap/XML-extraction tool and returns nonsense.

    Strategy:
      1. Search every message for <user_query> tags. Use the LAST match
         (that's the actual human turn).
      2. Fallback: drop system+tool roles, return last user message verbatim.
    """
    if not messages:
        return ""

    # 1. Look for <user_query> in any message (last wins).
    last_query = None
    for m in messages:
        content = _text(m.get("content", ""))
        if not content:
            continue
        matches = USER_QUERY_RE.findall(content)
        if matches:
            last_query = matches[-1].strip()
    if last_query:
        return last_query

    # 2. No <user_query> tag — drop system/tool, use last user content.
    user_msgs = [_text(m.get("content", "")).strip()
                 for m in messages if m.get("role") == "user"
                 and _text(m.get("content", "")).strip()]
    if user_msgs:
        return user_msgs[-1]

    return ""


# ============================================================================
# HTTP server
# ============================================================================

class Proxy:
    def __init__(self, cdp_port: int):
        self.cdp_port = cdp_port
        self.lock = asyncio.Lock()

    async def chat(self, request: web.Request) -> web.Response:
        try:
            req = await request.json()
        except Exception as e:
            return web.json_response(
                {"error": {"message": f"bad json: {e}",
                           "type": "proxy_error"}}, status=400)

        model = req.get("model", "grok-3")
        messages = req.get("messages", [])
        stream = bool(req.get("stream", False))
        prompt = flatten(messages)
        if not prompt:
            return web.json_response(
                {"error": {"message": "empty messages",
                           "type": "proxy_error"}}, status=400)
        log.info("prompt: %r%s",
                 prompt[:120], "…" if len(prompt) > 120 else "")

        async with self.lock:
            t0 = time.monotonic()
            try:
                tab = find_grok_tab(self.cdp_port)
                ws_url = tab["webSocketDebuggerUrl"]
                async with CDPSession(ws_url) as cdp:
                    # Enable domains BEFORE navigating so we don't miss
                    # any network events from page load.
                    await cdp.send("Page.enable", {})
                    await cdp.send("Network.enable", {})
                    await ensure_fresh_chat(cdp)
                    # Drain any events from navigation
                    while not cdp.event_queue.empty():
                        cdp.event_queue.get_nowait()
                    submit_info = await submit_prompt(cdp, prompt)
                    log.info("submitted via %s", submit_info)
                    body = await capture_chat_response(cdp)
                    text = parse_chat_body(body)
            except GrokError as e:
                log.warning("grok.com error: %s", e)
                return web.json_response(
                    {"error": {"message": str(e),
                               "type": "grok_com_error",
                               "code": "upstream_error"}}, status=429)
            except Exception as e:
                log.exception("turn failed")
                return web.json_response(
                    {"error": {"message": f"{type(e).__name__}: {e}",
                               "type": "proxy_error"}}, status=502)
            elapsed = time.monotonic() - t0
            log.info("OK %.1fs %d chars", elapsed, len(text))

        completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        created = int(time.time())

        if stream:
            resp = web.StreamResponse(
                status=200,
                headers={"content-type": "text/event-stream",
                         "cache-control": "no-cache",
                         "connection": "keep-alive"})
            await resp.prepare(request)
            # role chunk
            await resp.write(b"data: " + json.dumps({
                "id": completion_id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant"},
                              "finish_reason": None}]}).encode() + b"\n\n")
            # content chunks (word-split — text is already complete)
            for word in text.split(" "):
                await resp.write(b"data: " + json.dumps({
                    "id": completion_id, "object": "chat.completion.chunk",
                    "created": created, "model": model,
                    "choices": [{"index": 0,
                                  "delta": {"content": word + " "},
                                  "finish_reason": None}]}).encode() + b"\n\n")
            # done chunk
            await resp.write(b"data: " + json.dumps({
                "id": completion_id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [{"index": 0, "delta": {},
                              "finish_reason": "stop"}]}).encode() + b"\n\n")
            await resp.write(b"data: [DONE]\n\n")
            await resp.write_eof()
            return resp

        return web.json_response({
            "id": completion_id, "object": "chat.completion",
            "created": created, "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                      "total_tokens": 0},
        })

    async def models(self, _request: web.Request) -> web.Response:
        ids = ["grok-3", "grok-3-fast", "grok-3-mini-fast",
               "grok-4", "grok-4-latest", "grok-expert",
               "grok-code-fast-1", "grok-auto", "grok-4-auto"]
        return web.json_response({
            "object": "list",
            "data": [{"id": m, "object": "model", "created": int(time.time()),
                       "owned_by": "grok.com", "context_window": 131072,
                       "max_completion_tokens": 8192} for m in ids],
        })

    async def health(self, _request: web.Request) -> web.Response:
        try:
            list_tabs(self.cdp_port)
            return web.Response(text="ok\n")
        except Exception as e:
            return web.Response(text=f"chrome down: {e}\n", status=503)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--cdp", type=int, default=9222)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-5s %(message)s",
        datefmt="%H:%M:%S")

    try:
        tabs = list_tabs(args.cdp)
        log.info("Chrome at :%d — %d tabs", args.cdp, len(tabs))
    except Exception as e:
        sys.exit(str(e))

    proxy = Proxy(args.cdp)
    app = web.Application()
    app.router.add_post("/v1/chat/completions", proxy.chat)
    app.router.add_get("/v1/models", proxy.models)
    app.router.add_get("/health", proxy.health)

    log.info("grok-proxy listening on http://%s:%d", args.host, args.port)
    web.run_app(app, host=args.host, port=args.port, access_log=None)


if __name__ == "__main__":
    main()
