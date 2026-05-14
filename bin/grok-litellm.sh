#!/usr/bin/env bash
# grok-litellm — one-line launcher for grok-via-web + LiteLLM unified router.
#
# What it does:
#   1. Ensures the grok-via-web Chrome proxy is up on :8788
#      (it actually starts Chrome + the proxy through grok-via-web --noop-launch).
#   2. Installs LiteLLM into a managed venv if not present.
#   3. Starts the LiteLLM proxy on :4000 with our config.yaml.
#   4. Optionally execs the Grok CLI pointed at :4000, giving you:
#      - grok-3, grok-4, grok-auto via your grok.com session
#      - claude-sonnet-4.5, gpt-4o, gemini-2.5-pro, etc via OpenRouter
#        (if OPENROUTER_API_KEY is set)
#      - openai/<model>, anthropic/<model> via direct keys (if set)
#
# Usage:
#   grok-litellm                                  # just start the router (port 4000)
#   grok-litellm --grok                           # also launch the Grok TUI
#   grok-litellm --grok -m grok-3 -p "say hi"     # one-shot grok.com
#   grok-litellm --grok -m claude-sonnet-4.5 -p "..."  # one-shot via OpenRouter
#   grok-litellm --restart                        # kill+restart LiteLLM
#
# Environment:
#   OPENROUTER_API_KEY       # required for any openrouter/* models
#   OPENAI_API_KEY           # optional; for openai/* models
#   ANTHROPIC_API_KEY        # optional; for anthropic/* models
#   LITELLM_PORT             # default 4000
#   GROK_PROXY_PORT          # default 8788 (forwarded to grok-via-web)

set -euo pipefail

PROXY_DIR="${GROK_PROXY_DIR:-$HOME/.grok-proxy}"
LITELLM_PORT="${LITELLM_PORT:-4099}"
GROK_PROXY_PORT="${GROK_PROXY_PORT:-8788}"
GROK_BIN="${GROK_BIN:-$HOME/.grok/bin/grok}"
VENV_DIR="${PROXY_DIR}/venv"
CONFIG="${PROXY_DIR}/litellm-config.yaml"
LITELLM_LOG="/tmp/grok-litellm.log"

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yel()   { printf '\033[33m%s\033[0m' "$*"; }
c_cyan()  { printf '\033[36m%s\033[0m' "$*"; }

# ---- args -----------------------------------------------------------------
LAUNCH_GROK=0
RESTART=0
GROK_ARGS=()
for a in "$@"; do
  case "$a" in
    --grok)    LAUNCH_GROK=1 ;;
    --restart) RESTART=1 ;;
    *)         GROK_ARGS+=("$a") ;;
  esac
done

# ---- 1. grok-via-web proxy on :8788 --------------------------------------
if ! curl -sS --max-time 1 "http://localhost:${GROK_PROXY_PORT}/health" 2>/dev/null \
     | grep -q '^ok'; then
  echo "$(c_cyan '►') Starting grok-via-web Chrome proxy on :${GROK_PROXY_PORT}..." >&2
  # We use the standalone proxy_chrome.py (not the grok-via-web launcher),
  # because the launcher exec's into grok at the end.
  nohup python3 "${PROXY_DIR}/proxy_chrome.py" \
      --port "${GROK_PROXY_PORT}" \
      --cdp "${CHROME_CDP_PORT:-9222}" \
      > /tmp/grok-proxy-chrome.log 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if curl -sS --max-time 1 "http://localhost:${GROK_PROXY_PORT}/health" 2>/dev/null \
         | grep -q '^ok'; then break; fi
  done
fi
if curl -sS --max-time 1 "http://localhost:${GROK_PROXY_PORT}/health" 2>/dev/null \
     | grep -q '^ok'; then
  echo "$(c_green '✓') grok-via-web proxy up on :${GROK_PROXY_PORT}" >&2
else
  echo "$(c_red '✗') grok-via-web proxy failed to start" >&2
  echo "    Check Chrome at :9222 and run grok-via-web first." >&2
  echo "    Or see /tmp/grok-proxy-chrome.log" >&2
  exit 1
fi

# ---- 2. LiteLLM in managed venv -------------------------------------------
# Prefer Python 3.13 → 3.12 → 3.11 → 3.10, because LiteLLM's deps (orjson,
# pydantic-core) lag the bleeding edge and fail to build on Python 3.14.
PYBIN=""
for p in python3.13 python3.12 python3.11 python3.10; do
  if command -v "$p" >/dev/null 2>&1; then PYBIN="$(command -v "$p")"; break; fi
done
[ -z "$PYBIN" ] && PYBIN="$(command -v python3)"

if [ ! -d "$VENV_DIR" ]; then
  echo "$(c_cyan '►') Creating LiteLLM venv with $PYBIN (one-time setup)..." >&2
  "$PYBIN" -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
. "$VENV_DIR/bin/activate"

if ! python3 -c 'import litellm' 2>/dev/null; then
  echo "$(c_cyan '►') Installing LiteLLM into venv (one-time, ~30s)..." >&2
  pip install --quiet --upgrade pip
  pip install --quiet 'litellm[proxy]'
  echo "$(c_green '✓') LiteLLM installed" >&2
fi

# ---- 3. Start the LiteLLM router on :4000 --------------------------------
if [ "$RESTART" = 1 ]; then
  pkill -f "litellm.*--port[ =]${LITELLM_PORT}" 2>/dev/null || true
  pkill -f "litellm.*${CONFIG}" 2>/dev/null || true
  sleep 1
fi

if ! curl -sS --max-time 1 "http://localhost:${LITELLM_PORT}/health/liveliness" \
     2>/dev/null | grep -q 'alive\|{'; then
  echo "$(c_cyan '►') Starting LiteLLM proxy on :${LITELLM_PORT}..." >&2
  # Use the venv's litellm script directly (the litellm package has no __main__,
  # so `python3 -m litellm` fails).
  nohup "$VENV_DIR/bin/litellm" \
      --config "$CONFIG" \
      --port "$LITELLM_PORT" \
      --host 127.0.0.1 \
      --num_workers 1 \
      > "$LITELLM_LOG" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 1
    if curl -sS --max-time 1 "http://localhost:${LITELLM_PORT}/health/liveliness" \
         2>/dev/null | grep -q 'alive\|{'; then break; fi
  done
fi

if curl -sS --max-time 1 "http://localhost:${LITELLM_PORT}/health/liveliness" \
     2>/dev/null | grep -q 'alive\|{'; then
  echo "$(c_green '✓') LiteLLM router up on http://localhost:${LITELLM_PORT}/v1" >&2
else
  echo "$(c_red '✗') LiteLLM failed to start — see $LITELLM_LOG" >&2
  tail -20 "$LITELLM_LOG" >&2 || true
  exit 1
fi

# ---- 4. Status banner -----------------------------------------------------
KEYS=()
[ -n "${OPENROUTER_API_KEY:-}" ] && KEYS+=("OpenRouter")
[ -n "${OPENAI_API_KEY:-}" ]     && KEYS+=("OpenAI")
[ -n "${ANTHROPIC_API_KEY:-}" ]  && KEYS+=("Anthropic")

cat >&2 <<EOF

$(c_green '════════════════════════════════════════════════')
  grok-litellm running
  $(c_cyan 'Router'):          http://localhost:${LITELLM_PORT}/v1
  $(c_cyan 'grok-via-web'):    http://localhost:${GROK_PROXY_PORT}/v1 (via Chrome)
  $(c_cyan 'Provider keys'):   ${KEYS[@]:-(grok.com only)}
$(c_green '════════════════════════════════════════════════')

Models you can use:
  $(c_cyan 'grok-3, grok-4, grok-auto')          (uses your grok.com session)
EOF

if [ -n "${OPENROUTER_API_KEY:-}" ]; then
cat >&2 <<EOF
  $(c_cyan 'claude-sonnet-4.5, gpt-4o, gemini-2.5-pro') (via OpenRouter)
  $(c_cyan 'openrouter/<vendor>/<model>')         (any OpenRouter model)
EOF
else
cat >&2 <<EOF
  $(c_yel '! Set OPENROUTER_API_KEY to unlock claude/gpt/gemini/llama via OpenRouter')
EOF
fi

cat >&2 <<EOF

Example with curl:
  $(c_cyan "curl -sS http://localhost:${LITELLM_PORT}/v1/chat/completions -H 'content-type: application/json' \\
      -d '{\"model\":\"grok-3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")

Logs: $LITELLM_LOG
Stop: $(c_cyan 'grok-litellm --restart')  (or pkill -f litellm)

EOF

# ---- 5. Optionally launch the Grok CLI pointed at the router -------------
if [ "$LAUNCH_GROK" = 1 ]; then
  if [ ! -x "$GROK_BIN" ]; then
    echo "$(c_red '✗') Grok CLI not found at $GROK_BIN" >&2
    echo "    Install: curl -fsSL https://x.ai/cli/install.sh | bash" >&2
    exit 1
  fi
  # Wipe model cache so the CLI re-fetches our /v1/models list
  rm -f "$HOME/.grok/models_cache.json"
  export GROK_MODELS_BASE_URL="http://localhost:${LITELLM_PORT}/v1"
  export GROK_CODE_XAI_API_KEY="grok-litellm-dummy"
  echo "$(c_cyan '►') Launching Grok CLI via LiteLLM router..." >&2
  exec "$GROK_BIN" ${GROK_ARGS[@]+"${GROK_ARGS[@]}"}
fi
