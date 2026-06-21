#!/usr/bin/env bash
# ─── Critiq Install Script ─────────────────────────────────────────────────────
# Usage: curl -fsSL https://raw.githubusercontent.com/DrfterX/critiq/main/scripts/install.sh | bash
#
# Installs Critiq from source (no npm publish, no authentication required).
#
# What it does:
#   1. Clones the repo shallowly to /tmp/critiq-source
#   2. Builds Critiq CLI with esbuild
#   3. Installs the `critiq` command to /usr/local/bin (or ~/.local/bin)
#   4. Creates a wrapper that resolves to the source
#
# After install:
#   export CRITIQ_API_KEY=sk-your-key-here
#   critiq --help

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()   { echo -e "${RED}[ERR]${NC}   $1"; exit 1; }

echo ""
echo "  ╔═══════════════════════════╗"
echo "  ║   Critiq — AI Code Review ║"
echo "  ╚═══════════════════════════╝"
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v node >/dev/null 2>&1 || err "Node.js is required (v18+). Install from https://nodejs.org"
command -v npm >/dev/null 2>&1 || err "npm is required (ships with Node.js)"

NODE_VER=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VER" -lt 18 ]; then
  err "Node.js v18+ required. Current: $(node -v)"
fi
ok "Node.js $(node -v) + npm $(npm -v)"

# ─── Determine install directory ──────────────────────────────────────────────
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
  BIN_DIR="/usr/local/bin"
elif [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
  BIN_DIR="$HOME/.local/bin"
elif [ -w "$HOME" ]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  warn "Installing to ~/.local/bin — add it to your PATH:"
  echo "  export PATH=\$PATH:$BIN_DIR"
else
  err "No writable bin directory found. Try: sudo bash scripts/install.sh"
fi

# ─── Clone source ─────────────────────────────────────────────────────────────
CRITIQ_DIR="${CRITIQ_DIR:-$HOME/.critiq}"

if [ -d "$CRITIQ_DIR" ]; then
  info "Critiq source already exists at $CRITIQ_DIR — updating..."
  cd "$CRITIQ_DIR"
  git pull --ff-only origin main 2>/dev/null || warn "Could not update (local changes may exist)"
else
  info "Cloning Critiq source to $CRITIQ_DIR..."
  git clone --depth 1 https://github.com/DrfterX/critiq.git "$CRITIQ_DIR" 2>&1 || \
    err "Failed to clone repository. Check your internet connection."
  ok "Cloned to $CRITIQ_DIR"
fi

# ─── Install dependencies ─────────────────────────────────────────────────────
info "Installing dependencies..."
cd "$CRITIQ_DIR"
npm ci --no-audit --no-fund 2>&1 | tail -1
ok "Dependencies installed"

# ─── Build CLI ────────────────────────────────────────────────────────────────
info "Building Critiq CLI..."
node build.mjs
ok "CLI built at dist/cli.js"

# ─── Install command ──────────────────────────────────────────────────────────
cat > "$BIN_DIR/critiq" << 'SCRIPT'
#!/usr/bin/env bash
# Critiq wrapper — resolves to source installation
CRITIQ_HOME="${CRITIQ_HOME:-$HOME/.critiq}"
exec node "$CRITIQ_HOME/dist/cli.js" "$@"
SCRIPT
chmod +x "$BIN_DIR/critiq"
ok "Installed critiq command to $BIN_DIR/critiq"

# ─── Verify ───────────────────────────────────────────────────────────────────
if "$BIN_DIR/critiq" --help >/dev/null 2>&1; then
  ok "Installation verified!"
else
  warn "Command installed but verification failed. Run: critiq --help"
fi

# ─── Instructions ─────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                       ✅  Done!                             ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  To start using Critiq, set your API key and try it:"
echo ""
echo "    export CRITIQ_API_KEY=sk-your-key-here"
echo "    git diff HEAD~1 | critiq"
echo ""
echo "  Supported AI providers (set CRITIQ_API_BASE and CRITIQ_MODEL):"
echo ""
echo "    DeepSeek:"
echo "      CRITIQ_API_BASE=https://api.deepseek.com/v1"
echo "      CRITIQ_MODEL=deepseek-chat"
echo ""
echo "    OpenAI:"
echo "      CRITIQ_API_BASE=https://api.openai.com/v1"
echo "      CRITIQ_MODEL=gpt-4o-mini"
echo ""
echo "    Any OpenAI-compatible API:"
echo "      CRITIQ_API_BASE=https://your-api.example.com/v1"
echo "      CRITIQ_MODEL=your-model"
echo ""
echo "  GitHub Action (add to .github/workflows/):"
echo "    - uses: DrfterX/critiq/.github/actions/critiq-review@main"
echo "      with:"
echo "        api-key: \${{ secrets.CRITIQ_API_KEY }}"
echo "        github-token: \${{ secrets.GITHUB_TOKEN }}"
echo ""
echo "  Docs & source: https://github.com/DrfterX/critiq"
echo ""