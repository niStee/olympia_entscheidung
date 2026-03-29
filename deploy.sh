#!/usr/bin/env bash
# =============================================================================
# deploy.sh – Redeploy / update an already-installed server
#
# Syncs local files to the server and rebuilds containers.
# Assumes install.sh has been run at least once.
#
# Usage:
#   ./deploy.sh [--host user@host] [--key /path/to/key] [--test]
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }

# Load config
[[ -f "$SCRIPT_DIR/deploy.conf" ]] && source "$SCRIPT_DIR/deploy.conf"
SSH_HOST="${SSH_HOST:-}"
[[ -z "$SSH_HOST" ]] && { echo -e "${RED}ERROR:${NC} SSH_HOST is not set. Create deploy.conf or pass --host user@host"; exit 1; }
SSH_KEY="${SSH_KEY:-}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/wahl-check}"
PROJECT_NAME="${PROJECT_NAME:-wahl-check}"
APP_PORT="${APP_PORT:-8081}"
INFO_PORT="${INFO_PORT:-8083}"
DOMAIN="${DOMAIN:-}"
INFO_DOMAIN="${INFO_DOMAIN:-}"
TEST_MODE="${TEST_MODE:-false}"

# Parse overrides
while [[ $# -gt 0 ]]; do
  case $1 in
    --host) SSH_HOST="$2"; shift 2 ;;
    --key)  SSH_KEY="$2";  shift 2 ;;
    --test) TEST_MODE="true"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$TEST_MODE" == "true" ]]; then
  [[ "$REMOTE_APP_DIR" == "/opt/wahl-check" ]] && REMOTE_APP_DIR="/opt/wahl-check-test"
  [[ "$PROJECT_NAME" == "wahl-check" ]] && PROJECT_NAME="wahl-check-test"
  [[ "$APP_PORT" == "8081" ]] && APP_PORT="8082"
  [[ "$INFO_PORT" == "8083" ]] && INFO_PORT="8083"
fi

if [[ "$TEST_MODE" != "true" && -z "$INFO_DOMAIN" && -n "$DOMAIN" ]]; then
  INFO_DOMAIN="volt.${DOMAIN}"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes)
RSYNC_OPTS=(-az --delete --progress)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY") && RSYNC_OPTS+=(-e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new")

log "Syncing files to $SSH_HOST:$REMOTE_APP_DIR ..."

rsync "${RSYNC_OPTS[@]}" \
  --exclude='.next/' \
  --exclude='node_modules/' \
  --exclude='.git/' \
  --exclude='.env.local' \
  --exclude='.env' \
  --exclude='*.log' \
  --exclude='.DS_Store' \
  --filter=':- .gitignore' \
  "$SCRIPT_DIR/" \
  "$SSH_HOST:$REMOTE_APP_DIR/"

ok "Files synced"

log "Rebuilding and restarting containers..."
if [[ "$TEST_MODE" == "true" ]]; then
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" \
    "cd $REMOTE_APP_DIR && PROJECT_NAME='$PROJECT_NAME' APP_PORT='$APP_PORT' INFO_PORT='$INFO_PORT' QUIZ_URL='http://localhost:$APP_PORT' TEST_MODE='true' docker compose up --build -d --remove-orphans app info"
else
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" \
    "cd $REMOTE_APP_DIR && if [ -n '$INFO_DOMAIN' ]; then if grep -q '^INFO_DOMAIN=' .env 2>/dev/null; then sed -i \"s|^INFO_DOMAIN=.*|INFO_DOMAIN=$INFO_DOMAIN|\" .env; else printf '\nINFO_DOMAIN=%s\n' '$INFO_DOMAIN' >> .env; fi; fi && docker compose up --build -d --remove-orphans"
fi

if [[ "$TEST_MODE" == "true" ]]; then
  ok "Test deployment complete – server-local app on http://localhost:${APP_PORT}, info on http://localhost:${INFO_PORT}"
else
  ok "Deployment complete – https://$(grep '^DOMAIN=' "$SCRIPT_DIR/deploy.conf" 2>/dev/null | cut -d= -f2 || echo '<domain>')"
fi
