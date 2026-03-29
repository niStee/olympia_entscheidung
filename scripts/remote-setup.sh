#!/usr/bin/env bash
# =============================================================================
# scripts/remote-setup.sh – Runs ON the server (called by install.sh via SSH)
#
# Required environment variables (set by install.sh):
#   DOMAIN        Public domain name (e.g. example.com)
#   EMAIL         Email for Caddy TLS / Let's Encrypt
#   APP_PORT      Internal app port (default: 8081)
#   PROJECT_NAME  Container label prefix (default: wahl-check)
#   APP_DIR       Absolute path of the project on the server
# =============================================================================

set -Eeuo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[remote $(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[remote $(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[remote $(date +%H:%M:%S)] ⚠${NC} $*"; }
die()  { echo -e "${RED}[remote] ERROR: $*${NC}" >&2; exit 1; }

# ── Validate required env ─────────────────────────────────────────────────────
APP_PORT="${APP_PORT:-8081}"
INFO_PORT="${INFO_PORT:-8083}"
PROJECT_NAME="${PROJECT_NAME:-wahl-check}"
APP_DIR="${APP_DIR:-/opt/wahl-check}"
TEST_MODE="${TEST_MODE:-false}"
HOST_DATA_DIR="${HOST_DATA_DIR:-${APP_DIR}/data}"
INFO_DOMAIN="${INFO_DOMAIN:-}"
QUIZ_URL="${QUIZ_URL:-https://${DOMAIN:-localhost}}"

if [[ "$TEST_MODE" != "true" ]]; then
  : "${DOMAIN:?DOMAIN must be set}"
  : "${EMAIL:?EMAIL must be set}"
  [[ -z "$INFO_DOMAIN" ]] && INFO_DOMAIN="volt.${DOMAIN}"
fi

log "=== Remote Setup: $PROJECT_NAME ==="
log "  Domain  : $DOMAIN"
log "  Email   : $EMAIL"
log "  Port    : $APP_PORT"
log "  InfoPort: $INFO_PORT"
log "  Dir     : $APP_DIR"
log "  Test    : $TEST_MODE"
[[ -n "$INFO_DOMAIN" ]] && log "  Info    : $INFO_DOMAIN"

# ── 1. System packages ────────────────────────────────────────────────────────
install_system_packages() {
  export DEBIAN_FRONTEND=noninteractive

  # Remove any stale Docker apt source left from a previous failed run
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc

  log "Updating package lists..."
  apt-get update -qq

  log "Installing base packages..."
  apt-get install -y -qq \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    rsync \
    htop \
    unzip \
    apt-transport-https

  ok "Base packages installed"
}

# ── 2. Docker Engine ──────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
    if ! docker compose version &>/dev/null; then
      log "Installing Docker Compose plugin..."
      apt-get install -y -qq docker-compose-plugin
    fi
    return 0
  fi

  log "Installing Docker Engine (official method)..."

  # Detect OS family (ubuntu or debian) for correct repo URL
  local os_id
  os_id=$(. /etc/os-release && echo "${ID}")
  local codename
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")

  # Debian trixie (13) – use debian repo
  local repo_os="$os_id"
  if [[ "$os_id" != "ubuntu" && "$os_id" != "debian" ]]; then
    repo_os="debian"
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/${repo_os} \
    ${codename} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker

  ok "Docker installed: $(docker --version)"
  ok "Docker Compose: $(docker compose version)"
}

# ── 3. Firewall (UFW) ─────────────────────────────────────────────────────────
# Ports opened:
#   22   – SSH (always open, must remain open)
#   80   – HTTP (Caddy uses this for ACME challenge + redirect to HTTPS)
#   443  – HTTPS (public access)
#   443/udp – HTTP/3 QUIC
#   $APP_PORT – Localhost-only app access on host (for health checks / admin debugging)
configure_firewall() {
  if [[ "$TEST_MODE" == "true" ]]; then
    log "Skipping UFW changes for isolated test deployment"
    return 0
  fi

  log "Configuring UFW firewall..."

  # Add rules before enabling to avoid locking out SSH
  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  ufw allow 22/tcp    comment 'SSH'
  ufw allow 80/tcp    comment 'HTTP (ACME + redirect)'
  ufw allow 443/tcp   comment 'HTTPS'
  ufw allow 443/udp   comment 'HTTPS/QUIC'
  ufw --force enable

  ok "UFW active. Open ports: 22, 80, 443"
}

# ── 4. Generate .env ──────────────────────────────────────────────────────────
# This .env is read by Docker Compose on the server.
# It is NOT committed to the repository.
generate_env_file() {
  log "Generating .env file at ${APP_DIR}/.env ..."

  cat > "${APP_DIR}/.env" <<EOF
# Auto-generated by install.sh / remote-setup.sh
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Do not edit manually — re-run ./install.sh to regenerate

DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
APP_PORT=${APP_PORT}
INFO_PORT=${INFO_PORT}
PROJECT_NAME=${PROJECT_NAME}
INFO_DOMAIN=${INFO_DOMAIN}
INTERNAL_STATS_ENABLED=false
TEST_MODE=${TEST_MODE}
HOST_DATA_DIR=${HOST_DATA_DIR}
QUIZ_URL=${QUIZ_URL}

# Passed to the Next.js app container
NEXT_PUBLIC_APP_URL=https://${DOMAIN}
NODE_ENV=production
EOF

  ok ".env written"
}

# ── 5. Prepare host data directory ────────────────────────────────────────────
prepare_data_dir() {
  log "Preparing host data directory at ${HOST_DATA_DIR} ..."
  mkdir -p "${HOST_DATA_DIR}"
  chown 1001:1001 "${HOST_DATA_DIR}"
  chmod 0755 "${HOST_DATA_DIR}"
  ok "Host data directory ready"
}

# ── 6. Build & start containers ───────────────────────────────────────────────
deploy_containers() {
  log "Building and starting Docker containers..."
  cd "${APP_DIR}"

  if [[ "$TEST_MODE" != "true" ]]; then
    docker pull caddy:2-alpine --quiet || true
    docker compose down --remove-orphans 2>/dev/null || true
    docker compose up --build -d app caddy
  else
    PROJECT_NAME="$PROJECT_NAME" APP_PORT="$APP_PORT" INFO_PORT="$INFO_PORT" QUIZ_URL="$QUIZ_URL" TEST_MODE="$TEST_MODE" \
      docker compose stop app info 2>/dev/null || true
    PROJECT_NAME="$PROJECT_NAME" APP_PORT="$APP_PORT" INFO_PORT="$INFO_PORT" QUIZ_URL="$QUIZ_URL" TEST_MODE="$TEST_MODE" \
      docker compose rm -f app info 2>/dev/null || true
    PROJECT_NAME="$PROJECT_NAME" APP_PORT="$APP_PORT" INFO_PORT="$INFO_PORT" QUIZ_URL="$QUIZ_URL" TEST_MODE="$TEST_MODE" \
      docker compose up --build -d app info
  fi

  ok "Containers started"
  docker compose ps
}

# ── 7. Health check ───────────────────────────────────────────────────────────
health_check() {
  log "Waiting for app to respond on port ${APP_PORT}..."
  local max=18 attempt=0

  while [[ $attempt -lt $max ]]; do
    if curl -sf --max-time 3 "http://localhost:${APP_PORT}" > /dev/null 2>&1; then
      ok "App is responding: http://localhost:${APP_PORT}"
      return 0
    fi
    attempt=$((attempt + 1))
    warn "Attempt $attempt/$max – retrying in 5s..."
    sleep 5
  done

  warn "App did not respond within 90 seconds."
  warn "Check container logs with: docker compose -f ${APP_DIR}/docker-compose.yml logs app"
  return 0  # Non-fatal: container may still be building
}

# ── 8. Configure systemd for auto-restart on reboot ───────────────────────────
configure_autostart() {
  log "Configuring systemd service for auto-start on reboot..."

  local exec_start="/usr/bin/env PROJECT_NAME=${PROJECT_NAME} APP_PORT=${APP_PORT} TEST_MODE=${TEST_MODE} HOST_DATA_DIR=${HOST_DATA_DIR} /usr/bin/docker compose up -d --remove-orphans app caddy"
  local exec_stop="/usr/bin/env PROJECT_NAME=${PROJECT_NAME} APP_PORT=${APP_PORT} TEST_MODE=${TEST_MODE} HOST_DATA_DIR=${HOST_DATA_DIR} /usr/bin/docker compose down"
  if [[ "$TEST_MODE" == "true" ]]; then
    exec_start="/usr/bin/env PROJECT_NAME=${PROJECT_NAME} APP_PORT=${APP_PORT} INFO_PORT=${INFO_PORT} QUIZ_URL=${QUIZ_URL} TEST_MODE=${TEST_MODE} HOST_DATA_DIR=${HOST_DATA_DIR} /usr/bin/docker compose up -d --remove-orphans app info"
    exec_stop="/usr/bin/env PROJECT_NAME=${PROJECT_NAME} APP_PORT=${APP_PORT} INFO_PORT=${INFO_PORT} QUIZ_URL=${QUIZ_URL} TEST_MODE=${TEST_MODE} HOST_DATA_DIR=${HOST_DATA_DIR} /usr/bin/docker compose stop app info"
  fi

  cat > "/etc/systemd/system/${PROJECT_NAME}.service" <<EOF
[Unit]
Description=Wahl-Check Docker Compose Application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=${exec_start}
ExecStop=${exec_stop}
StandardOutput=journal
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${PROJECT_NAME}.service"

  ok "Systemd service '${PROJECT_NAME}' enabled (auto-starts on reboot)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Check if domain DNS resolves to this server's IP (warn only, non-fatal)
verify_dns() {
  if [[ "$TEST_MODE" == "true" ]]; then
    log "Skipping DNS verification for isolated test deployment"
    return 0
  fi

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')

  # Resolve domain – python3 handles Unicode/IDN domains correctly
  local resolved_ip=""
  if command -v python3 &>/dev/null; then
    resolved_ip=$(python3 -c \
      "import socket; print(socket.gethostbyname('${DOMAIN}'))" 2>/dev/null || true)
  else
    # Fallback: getent (may not handle IDN on all systems)
    resolved_ip=$(getent hosts "${DOMAIN}" 2>/dev/null | awk '{print $1}' || true)
  fi

  if [[ -z "$resolved_ip" ]]; then
    warn "DNS check: '${DOMAIN}' does not resolve yet."
    warn "→ Caddy HTTPS will fail until an A record points to ${server_ip}"
    warn "→ Add DNS A record:  ${DOMAIN}  →  ${server_ip}"
  elif [[ "$resolved_ip" != "$server_ip" ]]; then
    warn "DNS check: '${DOMAIN}' resolves to ${resolved_ip}, expected ${server_ip}"
    warn "→ Update the DNS A record to point to ${server_ip}"
  else
    ok "DNS check: '${DOMAIN}' → ${resolved_ip} ✓"
  fi
}

main() {
  install_system_packages
  install_docker
  configure_firewall
  generate_env_file
  prepare_data_dir
  verify_dns
  deploy_containers
  health_check
  configure_autostart

  echo ""
  ok "=== Remote setup complete ==="
  log "  Server-local app check : http://localhost:${APP_PORT}"
  if [[ "$TEST_MODE" == "true" ]]; then
    log "  Public site   : unchanged"
    log "  Caddy         : not started for test deployment"
    log "  Info test     : http://localhost:${INFO_PORT}"
  else
    log "  HTTPS (Caddy) : https://${DOMAIN}"
    log "  TLS cert      : provisioned automatically by Caddy (allow ~60s)"
  fi
  log "  Logs          : docker compose -f ${APP_DIR}/docker-compose.yml logs -f"
}

main
