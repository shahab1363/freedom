#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Freedom VPN Uninstall Script
# Removes all VPN components installed by freedom.sh from the server.
#
# Usage:
#   ./uninstall.sh                          # Interactive mode
#   ./uninstall.sh --ip 1.2.3.4 --pass x    # Non-interactive
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
ask()   { echo -en "${CYAN}[?]${NC} $1"; }

check_dependencies() {
  local missing=()
  command -v ssh     >/dev/null || missing+=(openssh)
  command -v sshpass >/dev/null || missing+=(sshpass)

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing dependencies: ${missing[*]}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "  brew install ${missing[*]}"
    else
      echo "  apt-get install -y ${missing[*]}"
    fi
    exit 1
  fi
}

main() {
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
  echo -e "${RED}║     Freedom VPN Uninstall Script         ║${NC}"
  echo -e "${RED}║  Removes all VPN components from server  ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
  echo ""

  check_dependencies

  local SERVER_IP=""
  local SERVER_PASS=""
  local SSH_USER="root"
  local DOMAIN=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --ip)     SERVER_IP="$2";    shift 2 ;;
      --pass)   SERVER_PASS="$2";  shift 2 ;;
      --user)   SSH_USER="$2";     shift 2 ;;
      --domain) DOMAIN="$2";       shift 2 ;;
      -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --ip IP            Server IP address"
        echo "  --pass PASSWORD    Server password"
        echo "  --user USER        SSH username (default: root, uses sudo for non-root)"
        echo "  --domain DOMAIN    Domain name (for certificate cleanup)"
        echo "  -h, --help         Show this help"
        exit 0
        ;;
      *) error "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Collect details interactively
  if [ -z "$SERVER_IP" ]; then
    ask "Server IP address: "
    read -r SERVER_IP
  fi

  if [ -z "$SERVER_PASS" ]; then
    ask "Password for $SSH_USER: "
    read -rs SERVER_PASS
    echo ""
  fi

  if [ "$SSH_USER" = "root" ]; then
    ask "SSH username [root]: "
    read -r input_user
    SSH_USER="${input_user:-root}"
  fi

  if [ -z "$DOMAIN" ]; then
    ask "Domain name (for certificate cleanup, or press Enter to skip): "
    read -r DOMAIN
  fi

  local SUDO=""
  if [ "$SSH_USER" != "root" ]; then
    SUDO="sudo"
    info "Using sudo for non-root user '$SSH_USER'"
  fi

  # Confirm
  echo ""
  warn "This will remove the following from $SERVER_IP:"
  echo "  - Xray (binary, config, service)"
  echo "  - Hysteria2 (binary, config, service)"
  echo "  - Nginx VPN site config"
  if [ -n "$DOMAIN" ]; then
    echo "  - TLS certificates for $DOMAIN"
    echo "  - APK files at /var/www/html/apps/"
  fi
  echo "  - VPN-related UFW firewall rules"
  echo ""
  ask "Are you sure? [y/N]: "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi

  info "Connecting to $SERVER_IP and removing VPN components..."

  local domain_cmds=""
  if [ -n "$DOMAIN" ]; then
    domain_cmds="
echo '>>> Removing TLS certificates...'
certbot delete --cert-name ${DOMAIN} --non-interactive 2>/dev/null || true
rm -rf /etc/letsencrypt/live/${DOMAIN} /etc/letsencrypt/archive/${DOMAIN} /etc/letsencrypt/renewal/${DOMAIN}.conf 2>/dev/null || true

echo '>>> Removing APK files...'
rm -rf /var/www/html/apps/
"
  fi

  sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "$SUDO bash -s" << REMOTE_SCRIPT
set -e

echo ">>> Stopping services..."
systemctl stop xray 2>/dev/null || true
systemctl stop hysteria-server 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
systemctl disable hysteria-server 2>/dev/null || true

echo ">>> Removing Xray..."
bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true
rm -rf /usr/local/etc/xray/ 2>/dev/null || true

echo ">>> Removing Hysteria2..."
rm -f /usr/local/bin/hysteria 2>/dev/null || true
rm -f /etc/systemd/system/hysteria-server.service 2>/dev/null || true
rm -f /etc/systemd/system/hysteria-server@.service 2>/dev/null || true
rm -rf /etc/hysteria/ 2>/dev/null || true
systemctl daemon-reload

echo ">>> Removing Nginx VPN config..."
rm -f /etc/nginx/sites-enabled/v2ray 2>/dev/null || true
rm -f /etc/nginx/sites-available/v2ray 2>/dev/null || true
# Restore default config if nginx is still installed
if command -v nginx >/dev/null 2>&1; then
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || true
fi

$domain_cmds

echo ">>> Removing VPN credentials..."
rm -f /root/.vpn-keys 2>/dev/null || true

echo ">>> Removing UFW firewall rules..."
ufw delete allow 2083/tcp 2>/dev/null || true
ufw delete allow 8388/tcp 2>/dev/null || true
ufw delete allow 8388/udp 2>/dev/null || true
ufw delete allow 8443/tcp 2>/dev/null || true
ufw delete allow 8443/udp 2>/dev/null || true

echo ">>> Uninstall complete."
REMOTE_SCRIPT

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        Uninstall Complete!                ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "  All VPN components have been removed from $SERVER_IP."
  echo "  Nginx is still installed but the VPN site config has been removed."
  echo ""
}

main "$@"
