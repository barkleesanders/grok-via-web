# grok-via-web

Use the [Grok CLI](https://x.ai/cli) (xAI's coding agent) with your **grok.com web
subscription** instead of an API key or the $300/mo *SuperGrok Heavy* tier.

Works by attaching to your already-signed-in Chrome via the DevTools Protocol,
typing prompts into the real grok.com web UI, and capturing the streaming
response back into an **OpenAI-compatible** `/v1/chat/completions` endpoint that
the CLI talks to transparently.

```
┌──────────┐    OpenAI /v1     ┌─────────────┐   CDP   ┌────────────┐   real session
│ grok CLI │ ────────────────► │ grok-proxy  │ ──────► │ Chrome tab │ ─────────────► grok.com
│ (binary) │ ◄──── tokens ──── │  (Python)   │ ◄────── │ (you, IRL) │ ◄────────────
└──────────┘                   └─────────────┘         └────────────┘
```

- ✅ Uses your existing grok.com subscription (free, Premium, SuperGrok)
- ✅ No reverse-engineered crypto, no Statsig bypass, no Cloudflare tricks
- ✅ All requests go through the genuine grok.com SPA — same auth your browser uses
- ✅ Works with `grok` interactive TUI and `grok -p "one-shot"` headless mode
- ⚠️  ~7-14s per turn (slower than a direct API)
- ⚠️  Each turn creates a chat entry in your grok.com sidebar history
- ⚠️  Stripped of CLI's system prompt — grok.com supplies its own and chokes on huge prepended instructions

---

## Install (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/barkleesanders/grok-via-web/main/install.sh | bash
```

This installs both modes:
1. **`grok-via-web`** — direct grok.com proxy
2. **`grok-litellm`** — LiteLLM router that adds OpenRouter / OpenAI / Anthropic on top

What runs:
1. Verifies Python 3.9+, `curl`
2. Downloads `proxy_chrome.py`, `grok-via-web.sh`, `grok-litellm.sh`, `litellm-config.yaml` to `~/.grok-proxy/`
3. `pip install aiohttp` (with `--user --break-system-packages` if needed)
4. Symlinks `~/.local/bin/grok-via-web` and `~/.local/bin/grok-litellm`
5. Runs a self-test if Chrome is reachable

Manual install:
```bash
git clone https://github.com/barkleesanders/grok-via-web ~/.grok-proxy
~/.grok-proxy/install.sh
```

### Add OpenRouter / OpenAI / Anthropic (optional)

To use `claude-sonnet-4.5`, `gpt-4o`, `gemini-2.5-pro`, etc through the same CLI:

```bash
# Pick one or more — only providers with keys will be routable
export OPENROUTER_API_KEY=sk-or-v1-...           # https://openrouter.ai/keys
export OPENAI_API_KEY=sk-...                     # https://platform.openai.com/api-keys
export ANTHROPIC_API_KEY=sk-ant-...              # https://console.anthropic.com

grok-litellm --grok -m claude-sonnet-4.5         # via OpenRouter
grok-litellm --grok -m grok-3                    # via your grok.com session
```

`grok-litellm` will:
- Boot the grok-via-web Chrome proxy on `:8788`
- Install LiteLLM into a managed venv at `~/.grok-proxy/venv` (one-time, ~30s)
- Start the LiteLLM router on `:4099`
- Optionally exec the Grok CLI pointed at the router

---

## Prerequisites

### 1. Install the Grok CLI

```bash
curl -fsSL https://x.ai/cli/install.sh | bash
```

Skip the `grok login` step — we'll point the CLI at our local proxy instead.

### 2. Start Chrome with remote debugging

Quit Chrome completely, then relaunch with the remote debugging port:

```bash
# macOS
open -a 'Google Chrome' --args --remote-debugging-port=9222 \
  --user-data-dir="$HOME/Library/Application Support/Google/Chrome"

# Linux
google-chrome --remote-debugging-port=9222 &

# Windows (PowerShell)
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222
```

> Why this: the proxy attaches to your live, signed-in Chrome via the Chrome
> DevTools Protocol on `localhost:9222`. Your existing grok.com session does
> all the actual auth work.

### 3. Sign in to grok.com in that Chrome

Just open [https://grok.com/](https://grok.com/) and sign in normally. The proxy
will detect or create a grok.com tab on first use.

> **No cookie export needed** — the proxy operates inside the live session, not
> by replaying captured cookies. (Earlier attempts to replay cookies in headless
> curl get 403'd by xAI's Statsig anti-bot.)

#### Optional: inspect/export your cookies

If you want to *see* what cookies your grok.com session is using (for curiosity
or to debug a different flow), the [Get cookies.txt Locally](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc)
Chrome extension exports them in Netscape format. **This repo does not need
that file** — it's purely for inspection. **Never share that file or paste it
anywhere** — it's a full session credential.

---

## Usage

```bash
# Interactive TUI
grok-via-web

# One-shot prompt
grok-via-web -p "what's the latest on the SF housing market?"

# Pick a model (default: grok-3 — equivalent to grok.com's Fast mode)
grok-via-web --model grok-4-auto -p "summarize this article"

# Continue last session
grok-via-web -c

# Force a fresh proxy
grok-via-web --restart -p "..."
```

All flags except `--restart` are forwarded to the `grok` binary verbatim.
See `grok --help` for the full list.

### Available models

These mirror what grok.com exposes for your account:

| Model id | grok.com mode | Notes |
|---|---|---|
| `grok-3` | Fast | Default; quick responses |
| `grok-3-fast` | Fast | Same as above |
| `grok-3-mini-fast` | Fast | Same as above |
| `grok-4` | Expert | Heavier reasoning |
| `grok-4-latest` | Expert | Same |
| `grok-expert` | Expert | Same |
| `grok-auto` | Auto | grok.com chooses Fast/Expert per turn |
| `grok-4-auto` | Auto | Same |
| `grok-code-fast-1` | Fast | Same |

> The proxy maps these to grok.com's three available `modeId` values
> (`fast`, `expert`, `auto`). `heavy` mode requires SuperGrok Heavy and is
> not exposed.

---

## How it works

For each `POST /v1/chat/completions` the CLI sends:

1. Proxy connects via WebSocket to Chrome at `:9222`.
2. Finds (or creates) a dedicated grok.com tab.
3. `Page.navigate` → `https://grok.com/` (fresh chat — keeps the sidebar tidy).
4. `Network.enable` + `Page.enable` — so we'll receive every fetch event.
5. `Runtime.evaluate` runs a small JS that:
   - Finds the prompt textarea (`[contenteditable="true"]`)
   - Inserts the user's flattened prompt via `document.execCommand('insertText', ...)` (triggers React's `onChange`)
   - Clicks the `Submit` button
6. Watches `Network.requestWillBeSent` for `POST /rest/app-chat/conversations/new`
   — captures the request ID.
7. On `Network.loadingFinished` for that ID, calls `Network.getResponseBody`
   to retrieve the **full NDJSON stream** the SPA consumed.
8. Parses the NDJSON event stream (same format as grok.com's web client):
   - `{result.response.token, messageTag:"final", isThinking:false}` → content delta
   - `{result.response.modelResponse.message}` → final assembled message
9. Returns it as OpenAI's `chat.completion` (or `chat.completion.chunk` SSE if `stream=true`).

The full response is fetched **after** grok.com finishes generating, so true
token-by-token streaming back to the CLI isn't implemented — the proxy fakes
it by word-splitting the complete text. (Real streaming via
`Fetch.continueResponse` or `Network.dataReceived` interception is a TODO.)

---

## Configuration

| Env var | Default | Notes |
|---|---|---|
| `GROK_PROXY_PORT` | `8788` | Where the proxy listens |
| `CHROME_CDP_PORT` | `9222` | Chrome remote-debugging port |
| `GROK_BIN` | `$HOME/.grok/bin/grok` | Path to the Grok CLI binary |
| `GROK_DEFAULT_MODEL` | `grok-3` | Forwarded to CLI |

These get overridden by the launcher and exposed to the `grok` binary:
- `GROK_MODELS_BASE_URL=http://localhost:8788/v1`
- `GROK_CODE_XAI_API_KEY=grok-via-web-dummy` (any non-empty string works)

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `❌ Chrome not reachable at :9222` | Restart Chrome with `--remote-debugging-port=9222` (see Prerequisites step 2) |
| `🚀 Starting grok-proxy` but `❌ Proxy didn't come up` | Check `/tmp/grok-proxy-chrome.log` for stack traces (often missing `aiohttp` → `pip install --user aiohttp`) |
| Proxy returns the wrong text (echoing CLI's system prompt) | Update — the latest version drops `role: system` messages before forwarding |
| Response comes back blank | grok.com may be rate-limiting your account. Check `https://grok.com/rest/rate-limits` in the browser. |
| Sidebar fills up with junk | Run `grok-via-web --restart` periodically; or open grok.com → History → bulk delete |
| `unbound variable: GROK_ARGS[@]` | Pre-2026-05-14 launcher bug. Update to latest: `curl -fsSL .../install.sh \| bash`. |

Verbose proxy logs:
```bash
pkill -f proxy_chrome.py
python3 ~/.grok-proxy/proxy_chrome.py --verbose
```

---

## Security

- The proxy listens on `127.0.0.1` only — never on a routable interface. Don't
  change this unless you fully understand what you're doing.
- Anyone with local access to your machine can drive grok.com as you while the
  proxy is up (same as anyone with access to your browser).
- The `GROK_CODE_XAI_API_KEY` value the launcher sets is a dummy — your real
  xAI API key is never read or transmitted.
- No cookies, session tokens, user IDs, or chat content are ever written to
  disk by this proxy. Logs at `/tmp/grok-proxy-chrome.log` contain prompt
  previews (first 120 chars) — delete if needed.

---

## TOS / legal

Driving grok.com via DevTools Protocol from your own browser is the same
operational pattern as a [Selenium](https://www.selenium.dev/) test or any
power-user automation. You're running a real signed-in browser session;
no credentials are being shared, replayed, or extracted. That said, **xAI's
ToS govern your use of grok.com** and may evolve — read them and use at your
own risk. This project is not affiliated with or endorsed by xAI.

---

## Why not just use the xAI API key?

You can — `console.x.ai` gives you per-token billing, no proxy needed, full
streaming, full feature set. Use that if:
- You don't mind paying per token (~$0.50–$5/M tokens depending on model)
- You don't already have a grok.com subscription
- You want streaming + tool use + system prompts to work properly

Use `grok-via-web` if:
- You already pay grok.com monthly and don't want to pay twice
- You want to use the Grok CLI without `grok login --oauth` requiring SuperGrok Heavy
- You don't care about ~10s latency overhead per turn

---

## License

MIT
