#!/usr/bin/env bash
# grok-via-web — one-shot launcher for Grok CLI using grok.com web session.
#
# What it does:
#   1. Verifies Chrome is running with --remote-debugging-port=9222 and that
#      you're signed in to grok.com (creates a tab if needed).
#   2. Starts the chrome-driving proxy on http://localhost:8788
#      (or reuses an already-running one).
#   3. Runs the Grok CLI with GROK_MODELS_BASE_URL pointed at the proxy.
#
# Usage:
#   grok-via-web                                  # interactive TUI
#   grok-via-web -p "say hi in 3 words"           # one-shot prompt
#   grok-via-web --model grok-4-auto -p "..."     # pick a model
#   grok-via-web --restart -p "..."               # force a fresh proxy
#
# All flags except --restart are forwarded to the grok binary.

set -euo pipefail

PROXY_DIR="$HOME/.grok-proxy"
PROXY_PORT="${GROK_PROXY_PORT:-8788}"
CDP_PORT="${CHROME_CDP_PORT:-9222}"
GROK_BIN="${GROK_BIN:-$HOME/.grok/bin/grok}"
LOG="/tmp/grok-proxy-chrome.log"

# --- args -----------------------------------------------------------------
RESTART=0
GROK_ARGS=()
for a in "$@"; do
  if [ "$a" = "--restart" ]; then
    RESTART=1
  else
    GROK_ARGS+=("$a")
  fi
done

# --- 1. Chrome reachable + signed in --------------------------------------
if ! curl -sS --max-time 2 "http://localhost:${CDP_PORT}/json/version" >/dev/null; then
  echo "❌ Chrome not reachable at :${CDP_PORT}." >&2
  echo "   Start Chrome with remote debugging:" >&2
  echo "   open -a 'Google Chrome' --args --remote-debugging-port=${CDP_PORT}" >&2
  exit 1
fi

# Ensure a grok.com tab exists and is logged in (best effort)
GROK_TAB=$(curl -sS "http://localhost:${CDP_PORT}/json" \
  | python3 -c 'import sys,json
tabs=[t for t in json.load(sys.stdin) if t.get("type")=="page"]
g=[t for t in tabs if "grok.com" in t.get("url","")]
print(g[0]["url"] if g else "")' 2>/dev/null || true)

if [ -z "$GROK_TAB" ]; then
  echo "ℹ️  No grok.com tab open — creating one." >&2
  curl -sS -X PUT "http://localhost:${CDP_PORT}/json/new?https://grok.com/" >/dev/null
  sleep 2
fi

# --- 2. Proxy --------------------------------------------------------------
if [ "$RESTART" = 1 ]; then
  pkill -f "proxy_chrome.py" 2>/dev/null || true
  sleep 1
fi

if ! curl -sS --max-time 2 "http://localhost:${PROXY_PORT}/health" >/dev/null 2>&1; then
  echo "🚀 Starting grok-proxy on http://localhost:${PROXY_PORT}" >&2
  nohup python3 "${PROXY_DIR}/proxy_chrome.py" \
    --port "${PROXY_PORT}" --cdp "${CDP_PORT}" \
    > "$LOG" 2>&1 &
  # Wait for /health to return ok (up to 10s)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if curl -sS --max-time 1 "http://localhost:${PROXY_PORT}/health" 2>/dev/null \
         | grep -q '^ok'; then
      echo "✅ Proxy up (log: $LOG)" >&2
      break
    fi
  done
fi

if ! curl -sS --max-time 1 "http://localhost:${PROXY_PORT}/health" 2>/dev/null \
     | grep -q '^ok'; then
  echo "❌ Proxy didn't come up. Check $LOG" >&2
  tail -20 "$LOG" >&2 || true
  exit 1
fi

# --- 3. Grok CLI -----------------------------------------------------------
export GROK_MODELS_BASE_URL="http://localhost:${PROXY_PORT}/v1"
export GROK_CODE_XAI_API_KEY="grok-via-web-dummy"
# Match the proxy's model list so the picker works
export GROK_DEFAULT_MODEL="${GROK_DEFAULT_MODEL:-grok-3}"

echo "💬 Launching Grok CLI via grok.com web session…" >&2
exec "$GROK_BIN" ${GROK_ARGS[@]+"${GROK_ARGS[@]}"}
