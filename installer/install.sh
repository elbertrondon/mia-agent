#!/usr/bin/env bash
# MIA Connector Agent — macOS & Linux installer
# Usage: sudo bash install.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_BIN="/usr/local/bin/mia-agent"
CONFIG_DIR="/etc/mia-agent"
CONFIG_FILE="$CONFIG_DIR/config.json"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▸ $*${RESET}"; }
success() { echo -e "${GREEN}✔ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
error()   { echo -e "${RED}✖ $*${RESET}"; exit 1; }
prompt()  { echo -e "${BOLD}$*${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  warn "Root privileges required. Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

# ── OS / arch detection ───────────────────────────────────────────────────────
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
  x86_64)          ARCH_SUFFIX="amd64" ;;
  aarch64 | arm64) ARCH_SUFFIX="arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

case "$OS" in
  darwin) BINARY_NAME="mia-agent-macos-${ARCH_SUFFIX}" ;;
  linux)  BINARY_NAME="mia-agent-linux-${ARCH_SUFFIX}" ;;
  *)
    error "Unsupported OS: $OS.\nFor Windows use the mia-agent-setup.exe installer."
    ;;
esac

# ── Locate binary ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="$SCRIPT_DIR/$BINARY_NAME"

if [ ! -f "$BINARY_PATH" ]; then
  # Fall back to a generic name in case the user renamed it
  BINARY_PATH="$SCRIPT_DIR/mia-agent"
fi

if [ ! -f "$BINARY_PATH" ]; then
  error "Binary not found. Expected '$BINARY_NAME' in the same folder as this script.\nDownload both files from https://github.com/elbertrondon/mia-agent/releases"
fi

# ── Welcome ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       MIA Connector Agent Installer      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo "This will install the MIA Agent as a system service."
echo "The agent connects your private database to MIA Platform"
echo "using only outbound HTTPS — no inbound ports required."
echo ""

# ── Config collection ─────────────────────────────────────────────────────────
echo -e "${BOLD}── MIA Platform ──────────────────────────────${RESET}"
echo ""

prompt "MIA URL (e.g. https://app.miaplatform.com):"
read -r MIA_URL
[ -z "$MIA_URL" ] && error "MIA URL is required."

prompt "Agent Token (from your MIA dashboard):"
read -r AGENT_TOKEN
[ ${#AGENT_TOKEN} -lt 32 ] && error "Agent Token must be at least 32 characters."

echo ""
echo -e "${BOLD}── Database ──────────────────────────────────${RESET}"
echo ""
echo "  1) MySQL"
echo "  2) PostgreSQL"
echo "  3) SQL Server"
echo "  4) SQLite"
echo ""
prompt "Database type [1-4]:"
read -r DB_CHOICE

case "$DB_CHOICE" in
  1) DB_DRIVER="mysql";    DEFAULT_PORT=3306 ;;
  2) DB_DRIVER="pgsql";    DEFAULT_PORT=5432 ;;
  3) DB_DRIVER="sqlsrv";   DEFAULT_PORT=1433 ;;
  4) DB_DRIVER="sqlite";   DEFAULT_PORT=0    ;;
  *) error "Invalid choice. Enter 1, 2, 3, or 4." ;;
esac

if [ "$DB_DRIVER" = "sqlite" ]; then
  prompt "SQLite file path (e.g. /var/data/mydb.sqlite):"
  read -r DB_HOST
  [ -z "$DB_HOST" ] && error "File path is required."
  DB_PORT=0
  DB_NAME=""
  DB_USER=""
  DB_PASS=""
else
  prompt "Host [localhost]:"
  read -r DB_HOST
  DB_HOST="${DB_HOST:-localhost}"

  prompt "Port [$DEFAULT_PORT]:"
  read -r DB_PORT
  DB_PORT="${DB_PORT:-$DEFAULT_PORT}"

  prompt "Database name:"
  read -r DB_NAME
  [ -z "$DB_NAME" ] && error "Database name is required."

  prompt "Username:"
  read -r DB_USER
  [ -z "$DB_USER" ] && error "Username is required."

  prompt "Password:"
  read -rs DB_PASS
  echo ""
fi

# ── JSON escape helper ────────────────────────────────────────────────────────
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ── Write config ──────────────────────────────────────────────────────────────
echo ""
info "Creating config at $CONFIG_FILE ..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "mia_url": "$(json_escape "$MIA_URL")",
  "agent_token": "$(json_escape "$AGENT_TOKEN")",
  "poll_interval_seconds": 3,
  "database": {
    "driver": "$DB_DRIVER",
    "host": "$(json_escape "$DB_HOST")",
    "port": $DB_PORT,
    "name": "$(json_escape "$DB_NAME")",
    "username": "$(json_escape "$DB_USER")",
    "password": "$(json_escape "$DB_PASS")"
  }
}
EOF
chmod 600 "$CONFIG_FILE"
success "Config written."

# ── Install binary ────────────────────────────────────────────────────────────
info "Installing binary to $INSTALL_BIN ..."
cp "$BINARY_PATH" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
success "Binary installed."

# ── Register and start service ────────────────────────────────────────────────
info "Installing system service ..."
# Stop + uninstall any existing service (ignore errors on first install)
"$INSTALL_BIN" -service stop      2>/dev/null || true
"$INSTALL_BIN" -service uninstall 2>/dev/null || true

if ! "$INSTALL_BIN" -config "$CONFIG_FILE" -service install; then
  error "Service installation failed. Check the binary and config, then run:\n  $INSTALL_BIN -config $CONFIG_FILE -service install"
fi
success "Service registered."

info "Starting service ..."
if ! "$INSTALL_BIN" -service start; then
  warn "Service installed but could not be started."
  warn "Check your database credentials and run: $INSTALL_BIN -service start"
else
  success "Service started."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
echo ""
echo "  Config:  $CONFIG_FILE"
echo "  Binary:  $INSTALL_BIN"
echo ""
echo "Useful commands:"
if [ "$OS" = "darwin" ]; then
  echo "  sudo launchctl list | grep mia    — check service status"
else
  echo "  sudo systemctl status MIAAgent    — check service status"
  echo "  sudo journalctl -u MIAAgent -f    — follow logs"
fi
echo "  $INSTALL_BIN -service stop        — stop the agent"
echo "  $INSTALL_BIN -service start       — start the agent"
echo "  $INSTALL_BIN -service uninstall   — remove the service"
echo ""
