# grok-via-web

Use the [Grok CLI](https://x.ai/cli) (xAI's coding agent) with your **grok.com
subscription** instead of an API key or the $300/mo *SuperGrok Heavy* tier —
plus optionally route to OpenRouter (incl. free models), OpenAI, Anthropic, or
a local model via LiteLLM, from the same CLI.

```
┌──────────┐   :4099 OpenAI    ┌──────────┐   :8788 OpenAI   ┌──────────────┐
│ grok TUI │ ─────────────────►│ LiteLLM  │ ────────────────►│ proxy_chrome │ ──► grok.com
│          │                   │ router   │                  │  (this repo) │
│          │                   │          │ ──► openrouter.ai (free/paid)
│          │                   │          │ ──► api.openai.com (if key)
│          │                   │          │ ──► api.anthropic.com (if key)
│          │                   │          │ ──► localhost:19100 (QClaw/local)
└──────────┘                   └──────────┘
```

The proxy talks to grok.com by driving your already-signed-in Chrome via the
DevTools Protocol — your real browser session does all the auth.

- ✅ Works with your existing grok.com plan (Free, Premium, SuperGrok)
- ✅ No reverse-engineered crypto, no Statsig bypass, no Cloudflare tricks
- ✅ All requests go through the genuine grok.com SPA — same auth your browser uses
- ✅ Interactive TUI and headless `-p "one-shot"` mode both work
- ✅ Multi-provider routing via LiteLLM with **free** OpenRouter models as fallback
- ✅ Defensive prompt-prefix neutralizes account-level Customize / Companion personas
- ⚠️  ~7-14s per turn (slower than a direct API)
- ⚠️  Each grok.com turn creates one chat entry in your grok.com sidebar
- ⚠️  Tool-calling (model invokes `read_file` etc) NOT supported — only text in / text out

---

## TL;DR — one line to install, one line to run

```bash
# Install (once)
curl -fsSL https://raw.githubusercontent.com/barkleesanders/grok-via-web/main/install.sh | bash

# Run (every time)
grok-litellm --grok
```

That's it. `grok-litellm --grok` boots the Chrome proxy, the LiteLLM router,
and the Grok CLI in one shot. Pick a specific model with `-m`:

```bash
grok-litellm --grok                              # default: grok-3 via your grok.com session
grok-litellm --grok -m grok-4-auto               # grok.com Auto mode (Fast or Expert)
grok-litellm --grok -m glm-4.5-air-free          # free via OpenRouter (needs OPENROUTER_API_KEY)
grok-litellm --grok -m claude-sonnet-4.5         # paid via OpenRouter
grok-litellm --grok -m m2                        # local QClaw on :19100 (if running)
grok-litellm --grok -p "summarise this PR"       # one-shot, no TUI
```

If you only ever want grok.com (no LiteLLM, no router), the lighter wrapper is:

```bash
grok-via-web                                     # interactive TUI
grok-via-web -p "your prompt"                    # one-shot
```

---

## Prerequisites

### 1. Grok CLI

```bash
curl -fsSL https://x.ai/cli/install.sh | bash
```

Skip the `grok login` step. The proxy intercepts inference before login is
checked. (If you do run `grok login --oauth`, it'll succeed but the resulting
token sits unused — the proxy uses your Chrome session instead.)

### 2. Chrome with remote debugging

Quit Chrome completely first, then relaunch with the remote debugging port:

```bash
# macOS
open -a 'Google Chrome' --args --remote-debugging-port=9222 \
  --user-data-dir="$HOME/Library/Application Support/Google/Chrome"

# Linux
google-chrome --remote-debugging-port=9222 &

# Windows (Git Bash / PowerShell)
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222
```

The `--user-data-dir` flag tells Chrome to reuse your existing profile (with
all your logged-in sessions and bookmarks). Without it Chrome would launch a
fresh empty profile.

### 3. Sign in to grok.com

Just open [https://grok.com/](https://grok.com/) in that Chrome and sign in
normally. The proxy detects an existing grok.com tab or creates one on first
use.

> No cookie export needed — the proxy operates inside the live browser
> session via the DevTools Protocol, not by replaying captured cookies.

### 4. (Optional) Add other providers

To unlock OpenRouter / OpenAI / Anthropic / local QClaw routing through the
same CLI, export their keys before running `grok-litellm`:

```bash
export OPENROUTER_API_KEY=sk-or-v1-...           # https://openrouter.ai/keys (free tier OK)
export OPENAI_API_KEY=sk-...                     # https://platform.openai.com/api-keys
export ANTHROPIC_API_KEY=sk-ant-...              # https://console.anthropic.com
```

Only providers with valid keys will be routable. Models requiring keys you
haven't set return a `401` if you select them; everything else keeps working.

---

## Model menu

`grok-litellm` exposes all of these via the OpenAI-compatible router at
`http://localhost:4099/v1`. List them at runtime with
`curl http://localhost:4099/v1/models | jq '.data[].id'`.

| Model id | Provider | Cost | Notes |
|---|---|---|---|
| `grok-3`, `grok-3-fast`, `grok-3-mini-fast` | grok.com / Fast mode | included in subscription | rate-limited 25/2h on Free tier |
| `grok-4`, `grok-4-latest`, `grok-expert` | grok.com / Expert mode | included | same rate limit |
| `grok-auto`, `grok-4-auto` | grok.com / Auto mode | included | grok.com picks Fast/Expert per turn |
| `grok-code-fast-1` | grok.com / Fast mode | included | mapped to Fast |
| `m2` | local QClaw @ `:19100` | $0 | needs QClaw running locally |
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
| `deepseek-v3.1` | OpenRouter paid | per-token | cheap reasoning |
| `llama-3.3-70b` | OpenRouter paid | per-token | open-weights |
| `openrouter/<vendor>/<model>` | OpenRouter passthrough | varies | any OpenRouter model id |
| `openai/<model>` | OpenAI direct | per-token | needs `OPENAI_API_KEY` |
| `anthropic/<model>` | Anthropic direct | per-token | needs `ANTHROPIC_API_KEY` |

> Free OpenRouter models have their own quotas (typically rate-limited per
> account / per day). Once exhausted you'll get a `429` — switch to another
> free model or a paid one.

---

## grok.com plan limits (what your subscription gets you here)

Verified against `https://grok.com/rest/rate-limits` on 2026-05-14:

| What | Limit |
|---|---|
| **Free tier**: queries per 2-hour rolling window | **25** (combined across `auto`/`fast`/`expert`) |
| **Premium / SuperGrok**: higher caps (talk to xAI) | not measured here |
| `heavy` mode (multi-expert) | Requires SuperGrok Heavy ($300/mo) — not routable from this proxy |
| Per-turn timeout | grok.com is patient; the proxy times out at 90s |
| File / image attachments | Not implemented — proxy is text-only |
| Tool use (the model calling functions back) | **NOT supported.** The Grok CLI's tool-call XML is stripped before forwarding |
| Streaming back to the CLI | Word-chunked SSE (the proxy fetches the full grok.com response, then word-splits it for streaming shape) |

**Check your remaining quota:** open
[https://grok.com/rest/rate-limits](https://grok.com/rest/rate-limits) in the
same Chrome (POST `{"modelName":"auto"}` from DevTools), or just keep using —
when you hit `0`, the proxy returns a clean `429` with the wait time in the
error message.

**When you hit the cap:** switch to a free model in the same command:

```bash
grok-litellm --grok -m glm-4.5-air-free          # OpenRouter, free
grok-litellm --grok -m m2                        # local QClaw, free (if running)
```

---

## How it works

For each `POST /v1/chat/completions` the CLI sends:

1. The proxy connects via WebSocket to Chrome at `:9222`.
2. Finds (or creates) a dedicated grok.com tab; sets a title marker so it can
   re-adopt the same tab on restart.
3. `Page.navigate` → `https://grok.com/` (fresh chat — keeps the sidebar tidy).
4. Enables `Network.*` + `Page.*` CDP domains so it'll see every fetch event.
5. Extracts the actual human-typed text from the CLI's ~100KB request (only the
   content inside the last `<user_query>…</user_query>` — drops the CLI's
   system prompt, tool schemas, MCP server list, and AGENTS.md verbatim
   contents that would otherwise confuse grok.com).
6. Prepends a defensive guard prefix that neutralizes any account-level
   Customize / Personality / Companion persona for that turn.
7. `Runtime.evaluate` runs a small JS that inserts the prompt into grok.com's
   contenteditable input and clicks the Submit button.
8. Watches `Network.requestWillBeSent` for
   `POST /rest/app-chat/conversations/new` — captures the request ID.
9. On `Network.loadingFinished` for that ID, calls `Network.getResponseBody`
   to retrieve the full NDJSON stream the SPA consumed.
10. Parses the NDJSON events (`token`, `messageTag:"final"`, `modelResponse`)
    into a single assistant message.
11. Returns it as OpenAI's `chat.completion` (or `chat.completion.chunk` SSE
    if `stream=true`).

The full response is fetched **after** grok.com finishes generating, so the
streaming is faked by word-splitting the complete text (TODO: real token-level
streaming via `Network.dataReceived` interception).

---

## Configuration

### Env vars

| Env var | Default | Used by | Notes |
|---|---|---|---|
| `OPENROUTER_API_KEY` | — | `grok-litellm` | required for any `openrouter/*` or `*-free` model |
| `OPENAI_API_KEY` | — | `grok-litellm` | required for `openai/*` and `gpt-*` |
| `ANTHROPIC_API_KEY` | — | `grok-litellm` | required for `anthropic/*` and `claude-*` |
| `GROK_PROXY_PORT` | `8788` | both | where `proxy_chrome.py` listens |
| `LITELLM_PORT` | `4099` | `grok-litellm` | where the LiteLLM router listens |
| `CHROME_CDP_PORT` | `9222` | both | Chrome remote-debugging port |
| `GROK_BIN` | `$HOME/.grok/bin/grok` | both | path to the Grok CLI binary |
| `GROK_DEFAULT_MODEL` | `grok-3` | both | forwarded to the CLI |
| `GROK_PROXY_DIR` | `$HOME/.grok-proxy` | install + run | install dir |

The launcher sets these for the `grok` binary automatically:

- `GROK_MODELS_BASE_URL=http://localhost:4099/v1` (router) or `8788/v1` (direct)
- `GROK_CODE_XAI_API_KEY=grok-via-web-dummy` (any non-empty string — real xAI key never read)

### Files installed by `install.sh`

```
~/.grok-proxy/
├── proxy_chrome.py        # the Chrome-driving OpenAI-compatible proxy
├── grok-via-web.sh        # direct-mode launcher
├── grok-litellm.sh        # router-mode launcher (Chrome proxy + LiteLLM)
├── litellm-config.yaml    # LiteLLM model list (edit to add models)
└── venv/                  # managed Python venv with LiteLLM (created on first grok-litellm run)

~/.local/bin/
├── grok-via-web → ~/.grok-proxy/grok-via-web.sh
└── grok-litellm → ~/.grok-proxy/grok-litellm.sh
```

### Adding more models

Edit `~/.grok-proxy/litellm-config.yaml` and append entries under
`model_list:`. Any LiteLLM-supported provider works. Examples:

```yaml
  - model_name: my-local-ollama
    litellm_params:
      model: ollama/llama3.3:70b
      api_base: http://localhost:11434
      api_key: ollama

  - model_name: my-custom-endpoint
    litellm_params:
      model: openai/whatever
      api_base: https://my.endpoint.example.com/v1
      api_key: os.environ/MY_CUSTOM_KEY
```

Then `grok-litellm --restart` to reload.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| TUI says "Turn completed in 4s" with no answer | grok.com hit the 25 queries / 2h Free-tier cap. Check `https://grok.com/rest/rate-limits` for `waitTimeSeconds`. Switch to a free model: `grok-litellm --grok -m glm-4.5-air-free`. The proxy now surfaces this as a `429` instead of silent empty. |
| Replies stuck in a persona (sitemap parser, Ani, concise mode, …) | Your grok.com Customize / Companion / Personality is leaking through. The proxy ships with a guard prefix that neutralizes most cases — if yours is unusually strong, clear it at [grok.com/settings/customize](https://grok.com/settings/customize). |
| Sitemap-flavored nonsense in every reply | Pre-2026-05-14 flatten bug. Run `curl -fsSL .../install.sh \| bash` to upgrade. |
| `❌ Chrome not reachable at :9222` | Restart Chrome with `--remote-debugging-port=9222` (Prerequisites step 2). |
| `🚀 Starting grok-proxy` then `❌ Proxy didn't come up` | Check `/tmp/grok-proxy-chrome.log` — usually missing `aiohttp` → `pip install --user aiohttp`. |
| `❌ Proxy didn't come up` for `grok-litellm` | LiteLLM venv build failed. Check `/tmp/grok-litellm.log`. Common: Python 3.14 → `orjson` build fails. Fix: `rm -rf ~/.grok-proxy/venv && grok-litellm` — the launcher prefers 3.13 → 3.12 → 3.11 if available. |
| LiteLLM 401 "User not found" on a free OpenRouter model | `OPENROUTER_API_KEY` is invalid/revoked. Mint a fresh key at https://openrouter.ai/keys and re-export. |
| LiteLLM 429 "Too many requests" on `grok-3` | grok.com rate limit upstream — switch to a free/paid OpenRouter model. |
| Sidebar fills up with junk | grok.com → History → bulk delete. |
| Port 4099 or 8788 already taken | Override: `LITELLM_PORT=4100 grok-litellm --grok` or `GROK_PROXY_PORT=8789 grok-via-web`. |
| `unbound variable: GROK_ARGS[@]` | Pre-2026-05-14 launcher bug. Re-install. |

### Verbose logs

```bash
# Chrome proxy
pkill -f proxy_chrome.py
python3 ~/.grok-proxy/proxy_chrome.py --verbose

# LiteLLM router log
tail -f /tmp/grok-litellm.log
```

### Stop everything

```bash
pkill -f proxy_chrome.py
pkill -f 'litellm.*4099'
```

---

## Security

- The proxy listens on `127.0.0.1` only — never on a routable interface.
- Anyone with local access to your machine can drive grok.com as you while
  the proxy is up (same threat model as anyone with access to your browser).
- The `GROK_CODE_XAI_API_KEY=grok-via-web-dummy` value the launcher sets is
  a placeholder — your real xAI API key (if any) is never read or sent.
- No cookies, session tokens, user IDs, or chat content are ever written to
  disk by this proxy. Logs at `/tmp/grok-proxy-chrome.log` contain prompt
  previews (first 120 chars) — delete if needed.
- `litellm-config.yaml` uses `os.environ/NAME` syntax for all keys — actual
  key values stay in your shell environment and are never committed.

---

## TOS / legal

Driving grok.com via DevTools Protocol from your own signed-in browser is
the same operational pattern as a [Selenium](https://www.selenium.dev/) test
or any power-user automation. You're running a real browser session; no
credentials are shared, replayed, or extracted. That said, **xAI's ToS
govern your use of grok.com** and may evolve — read them and use at your own
risk. This project is not affiliated with or endorsed by xAI.

---

## Why not just use the xAI API key?

If you have it, **do** use it — [console.x.ai](https://console.x.ai) gives
you per-token billing, no proxy needed, real streaming, and full feature
support including tool use and system prompts.

Use this project if:

- You already pay grok.com monthly and don't want to pay twice
- You want to use the Grok CLI without `grok login --oauth` requiring
  SuperGrok Heavy ($300/mo)
- You want a single CLI that can also tap free OpenRouter models and your
  own local backends
- You don't care about ~10s latency overhead per turn

---

## Repo layout

```
bin/proxy_chrome.py        # the Chrome-driving OpenAI-compatible proxy
bin/grok-via-web.sh        # direct-mode launcher (grok.com only)
bin/grok-litellm.sh        # router-mode launcher (multi-provider via LiteLLM)
bin/litellm-config.yaml    # LiteLLM router config
docs/grok-cli-system-prompt.txt   # the Grok CLI's own system prompt (captured for reference)
install.sh                 # one-line installer
README.md                  # this file
LICENSE                    # MIT
```

---

## License

MIT — see [LICENSE](LICENSE).
