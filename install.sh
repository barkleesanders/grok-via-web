#!/usr/bin/env bash
# grok-via-web — one-line installer.
#
# Run via:
#   curl -fsSL https://raw.githubusercontent.com/barkleesanders/grok-via-web/main/install.sh | bash
#
# Or manually:
#   git clone https://github.com/barkleesanders/grok-via-web ~/.grok-proxy
#   ~/.grok-proxy/install.sh

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/barkleesanders/grok-via-web/main"
INSTALL_DIR="${GROK_PROXY_DIR:-$HOME/.grok-proxy}"
BIN_LINK_DIR="${GROK_BIN_DIR:-$HOME/.local/bin}"
CDP_PORT="${CHROME_CDP_PORT:-9222}"

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yel()   { printf '\033[33m%s\033[0m' "$*"; }
c_cyan()  { printf '\033[36m%s\033[0m' "$*"; }

step() { printf '\n%s %s\n' "$(c_cyan '►')" "$*"; }
ok()   { printf '%s %s\n' "$(c_green '✓')" "$*"; }
warn() { printf '%s %s\n' "$(c_yel '!')" "$*"; }
die()  { printf '%s %s\n' "$(c_red '✗')" "$*" >&2; exit 1; }

# ---- 1. Pre-flight ---------------------------------------------------------

step "Pre-flight checks"

command -v python3 >/dev/null || die "python3 not found (install Python 3.9+)"
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
case "$PYV" in
  3.[0-8]) die "python3 $PYV is too old — need 3.9+" ;;
  *) ok "python3 $PYV" ;;
esac

command -v curl >/dev/null || die "curl not found"
ok "curl present"

# ---- 2. Files --------------------------------------------------------------

step "Downloading files to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_LINK_DIR"

# If we're running from inside a clone of the repo, copy local files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/bin/proxy_chrome.py" ]; then
  cp "$SCRIPT_DIR/bin/proxy_chrome.py" "$INSTALL_DIR/proxy_chrome.py"
  cp "$SCRIPT_DIR/bin/grok-via-web.sh" "$INSTALL_DIR/grok-via-web.sh"
  ok "Copied from local checkout: $SCRIPT_DIR"
else
  curl -fsSL "$REPO_RAW/bin/proxy_chrome.py" -o "$INSTALL_DIR/proxy_chrome.py"
  curl -fsSL "$REPO_RAW/bin/grok-via-web.sh" -o "$INSTALL_DIR/grok-via-web.sh"
  ok "Downloaded from $REPO_RAW"
fi
chmod +x "$INSTALL_DIR/grok-via-web.sh"

# ---- 3. Python deps --------------------------------------------------------

step "Python dependencies (aiohttp)"
if python3 -c 'import aiohttp' 2>/dev/null; then
  ok "aiohttp already installed"
else
  # Try in order: --user, --break-system-packages, pipx, plain pip
  if python3 -m pip install --user --quiet aiohttp 2>/dev/null; then
    ok "Installed aiohttp (--user)"
  elif python3 -m pip install --user --quiet --break-system-packages aiohttp 2>/dev/null; then
    ok "Installed aiohttp (--user --break-system-packages)"
  elif python3 -m pip install --quiet aiohttp 2>/dev/null; then
    ok "Installed aiohttp (system)"
  else
    die "Failed to install aiohttp. Run: python3 -m pip install --user aiohttp"
  fi
fi

# ---- 4. Symlink ------------------------------------------------------------

step "Linking to $BIN_LINK_DIR/grok-via-web"
ln -sf "$INSTALL_DIR/grok-via-web.sh" "$BIN_LINK_DIR/grok-via-web"
ok "Symlinked"

case ":$PATH:" in
  *":$BIN_LINK_DIR:"*) ok "$BIN_LINK_DIR is on PATH" ;;
  *)
    warn "$BIN_LINK_DIR is NOT on PATH. Add this to your shell rc:"
    case "${SHELL##*/}" in
      fish) printf '  fish_add_path %s\n' "$BIN_LINK_DIR" ;;
      *)    printf '  export PATH="%s:$PATH"\n' "$BIN_LINK_DIR" ;;
    esac
    ;;
esac

# ---- 5. Sanity check -------------------------------------------------------

step "Sanity check"

# Grok CLI present?
if [ -x "$HOME/.grok/bin/grok" ]; then
  ok "Grok CLI installed at $HOME/.grok/bin/grok"
else
  warn "Grok CLI not found at $HOME/.grok/bin/grok"
  warn "Install with: curl -fsSL https://x.ai/cli/install.sh | bash"
fi

# Chrome reachable?
if curl -sS --max-time 2 "http://localhost:${CDP_PORT}/json/version" >/dev/null 2>&1; then
  ok "Chrome reachable at :${CDP_PORT}"
  GROK_TABS=$(curl -sS "http://localhost:${CDP_PORT}/json" | \
    python3 -c 'import sys,json
tabs=[t for t in json.load(sys.stdin) if t.get("type")=="page" and "grok.com" in t.get("url","")]
print(len(tabs))' 2>/dev/null || echo "0")
  if [ "$GROK_TABS" -gt 0 ]; then
    ok "Found $GROK_TABS open grok.com tab(s)"
  else
    warn "No grok.com tab open — grok-via-web will create one (sign in there first)"
  fi
else
  warn "Chrome not running with --remote-debugging-port=${CDP_PORT}"
  warn "Start it with:"
  case "$(uname -s)" in
    Darwin) printf "  open -a 'Google Chrome' --args --remote-debugging-port=%s\n" "$CDP_PORT" ;;
    Linux)  printf "  google-chrome --remote-debugging-port=%s &\n" "$CDP_PORT" ;;
  esac
fi

cat <<EOF

$(c_green '════════════════════════════════════════════════')
$(c_green '  grok-via-web installed')
$(c_green '════════════════════════════════════════════════')

Run:
  $(c_cyan 'grok-via-web')                              # interactive TUI
  $(c_cyan 'grok-via-web -p "hello"')                   # one-shot
  $(c_cyan 'grok-via-web --model grok-4-auto')          # pick a model

If 'grok-via-web' isn't found, restart your shell or run:
  $(c_cyan "export PATH=\"$BIN_LINK_DIR:\$PATH\"")

Files installed:
  $INSTALL_DIR/proxy_chrome.py
  $INSTALL_DIR/grok-via-web.sh
  $BIN_LINK_DIR/grok-via-web → $INSTALL_DIR/grok-via-web.sh

Repo: https://github.com/barkleesanders/grok-via-web

EOF
