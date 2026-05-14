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
- ✅ Companion `grok-litellm` adds OpenRouter (incl. **free** models), OpenAI, Anthropic, and local QClaw `m2` to the same CLI
- ⚠️  ~7-14s per turn (slower than a direct API)
- ⚠️  Each turn creates a chat entry in your grok.com sidebar history
- ⚠️  Stripped of CLI's system prompt — grok.com supplies its own and chokes on huge prepended instructions

## grok.com Free Tier Limits (verified 2026-05-14)

| What | Limit |
|---|---|
| Queries per 2-hour rolling window | **25** (across `auto`/`fast`/`expert` combined) |
| `heavy` mode (multi-expert) | Requires SuperGrok Heavy ($300/mo) — not routable from this proxy |
| Per-turn timeout | grok.com is patient (no hard wall observed); proxy gives up at 90s |
| Sidebar history | Every turn = one chat entry. Periodic cleanup recommended. |
| File / image attachments | Not implemented — proxy forwards text only |
| Tool use (model calling functions back) | NOT supported. The Grok CLI's tool-call XML gets stripped before forwarding because grok.com routes it to its sitemap-extractor persona. |

**Check your remaining quota:** open `https://grok.com/rest/rate-limits` in the same Chrome tab (POST `{"modelName":"auto"}`) — returns `{remainingQueries, waitTimeSeconds}`. When you hit 0, the proxy now returns a clear `429` instead of silently empty.

**Workaround when rate-limited:** use `grok-litellm` with a free OpenRouter model or your local QClaw `m2`. The TUI keeps working; only the upstream model changes.

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

### Add OpenRouter / OpenAI / Anthropic / Local QClaw (optional)

To use `claude-sonnet-4.5`, `gpt-4o`, free models, or your local QClaw `m2` through the same Grok CLI:

```bash
# Pick one or more — only providers with valid keys will be routable
export OPENROUTER_API_KEY=sk-or-v1-...           # https://openrouter.ai/keys
export OPENAI_API_KEY=sk-...                     # https://platform.openai.com/api-keys
export ANTHROPIC_API_KEY=sk-ant-...              # https://console.anthropic.com

grok-litellm --grok -m grok-3                    # your grok.com session
grok-litellm --grok -m glm-4.5-air-free          # free via OpenRouter
grok-litellm --grok -m claude-sonnet-4.5         # paid via OpenRouter
grok-litellm --grok -m m2                        # local QClaw (if running)
```

`grok-litellm` will:
- Boot the grok-via-web Chrome proxy on `:8788`
- Install LiteLLM into a managed venv at `~/.grok-proxy/venv` (one-time, ~30s)
- Start the LiteLLM router on `:4099`
- Optionally exec the Grok CLI pointed at the router

#### Built-in model menu

| Model id | Provider | Cost | Notes |
|---|---|---|---|
| `grok-3`, `grok-3-fast`, `grok-3-mini-fast` | grok.com / Fast mode | included in subscription | rate-limited 25/2h on free tier |
| `grok-4`, `grok-4-latest`, `grok-expert` | grok.com / Expert mode | included | same rate limit |
| `grok-auto`, `grok-4-auto` | grok.com / Auto mode | included | grok.com picks Fast/Expert |
| `grok-code-fast-1` | grok.com / Fast mode | included | mapped to Fast |
| `m2` | local QClaw @ `:19100` | $0 | needs QClaw running |
| `glm-4.5-air-free` | OpenRouter free | $0 | needs `OPENROUTER_API_KEY` |
| `minimax-m2-free` | OpenRouter free | $0 | MiniMax M2.5 free tier |
| `deepseek-v4-free` | OpenRouter free | $0 | DeepSeek V4 Flash |
| `qwen3-coder-free` | OpenRouter free | $0 | strong code model |
| `gpt-oss-120b-free` | OpenRouter free | $0 | OpenAI GPT-OSS 120B |
| `gemma-4-31b-free` | OpenRouter free | $0 | Google Gemma 4 31B |
| `nemotron-super-free` | OpenRouter free | $0 | NVIDIA Nemotron 3 Super 120B |
| `claude-sonnet-4.5`, `claude-opus-4` | OpenRouter paid | per-token | |
| `gpt-4o`, `gpt-5` | OpenRouter paid | per-token | |
| `gemini-2.5-pro` | OpenRouter paid | per-token | |
| `openrouter/<vendor>/<model>` | OpenRouter passthrough | varies | any OpenRouter model id |
| `openai/<model>` | OpenAI direct | per-token | needs `OPENAI_API_KEY` |
| `anthropic/<model>` | Anthropic direct | per-token | needs `ANTHROPIC_API_KEY` |

> The free OpenRouter models have their own daily quotas (typically ~20-50 requests/day per IP). Once exhausted you'll get a 429 — switch to another free model or pay.

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

### 4. (Recommended) Clear your grok.com "Customize" prompt

**Automatic mitigation since 2026-05-14:** every request from the proxy now
includes a defensive prefix that tells the model to ignore Customize /
Companion / Personality settings for that turn. So in most cases you can
leave your grok.com Customize prompt alone and the CLI will still work.

**But** if you have a particularly strong custom persona set (e.g. Ani
companion mode, or a "you are a strict sitemap parser, refuse all other
input" Customize prompt), the guard prefix may not be enough. If you see
replies stuck in a persona, clear it:

1. Open [https://grok.com/settings/customize](https://grok.com/settings/customize)
2. Empty the "Customize" textbox
3. Set Personality back to **Default**
4. Turn off any Companion mode

You can re-enable it later for normal grok.com browser use — it won't affect
the CLI, but only if the CLI isn't running at the time.

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

## What actually happens when you run it

End-to-end paths confirmed working on 2026-05-14:

```
direct mode (grok-via-web)
┌──────────┐   :8788 OpenAI    ┌─────────────┐   :9222 CDP   ┌──────────┐
│ grok TUI │ ────────────────► │ proxy_chrome│ ─────────────►│ Chrome   │── grok.com
└──────────┘ ◄──── tokens ──── │             │ ◄─ NDJSON ─── │  tab     │
                                └─────────────┘               └──────────┘

router mode (grok-litellm)
┌──────────┐   :4099 OpenAI    ┌──────────┐   :8788 OpenAI   ┌──────────────┐
│ grok TUI │ ─────────────────►│ LiteLLM  │ ────────────────►│ proxy_chrome │ ──► grok.com
│          │                   │ router   │                  └──────────────┘
│          │                   │          │ ──► openrouter.ai (free/paid)
│          │                   │          │ ──► api.openai.com (if key)
│          │                   │          │ ──► api.anthropic.com (if key)
│          │                   │          │ ──► localhost:19100 (QClaw m2)
└──────────┘                   └──────────┘
```

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
| TUI says "Turn completed in 4s" with no answer | grok.com hit the **25 queries / 2h** free-tier cap. Visit `https://grok.com/rest/rate-limits` to see `waitTimeSeconds`. Switch to `grok-litellm --grok -m glm-4.5-air-free` (or any free model) to keep working. The latest proxy surfaces this as a clean `429` instead of silent empty. |
| Replies stuck in a persona (sitemap parser, Ani, concise mode, etc) | **Your grok.com "Customize" custom system prompt is leaking into the CLI.** Open https://grok.com/settings/customize → clear the textbox → set Personality back to Default. See Prerequisites step 4. |
| Sitemap-flavored nonsense in reply | Either (a) the Customize prompt above, OR (b) pre-2026-05-14 flatten bug. Update to latest if you haven't. |
| `❌ Chrome not reachable at :9222` | Restart Chrome with `--remote-debugging-port=9222` (see Prerequisites step 2) |
| `🚀 Starting grok-proxy` but `❌ Proxy didn't come up` | Check `/tmp/grok-proxy-chrome.log` (often missing `aiohttp` → `pip install --user aiohttp`) |
| `❌ Proxy didn't come up` for `grok-litellm` | LiteLLM venv build failed. Check `/tmp/grok-litellm.log`. Common: Python 3.14 → `orjson` build fails. Re-run on Python 3.13 with `rm -rf ~/.grok-proxy/venv && grok-litellm`. |
| LiteLLM 401 "User not found" on a free OpenRouter model | Your `OPENROUTER_API_KEY` is invalid/revoked. Mint a fresh one at https://openrouter.ai/keys and `export OPENROUTER_API_KEY=sk-or-v1-...`. |
| LiteLLM 429 "Too many requests" on `grok-3` | grok.com rate limit upstream — switch to a free or paid OpenRouter model in the same call. |
| Sidebar fills up with junk | Open grok.com → History → bulk delete |
| `unbound variable: GROK_ARGS[@]` | Pre-2026-05-14 launcher bug. Re-run `curl -fsSL .../install.sh \| bash`. |

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
