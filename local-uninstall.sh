#!/usr/bin/env bash
# Remove a local (non-AWS) AgentOffice install.
#
# Stops and disables the services, removes the agent users, and deletes the
# config/data the bootstrap created. It does NOT touch Redis, nginx, or any
# package you might already have had installed.
#
# Usage:
#   sudo ./local-uninstall.sh --yes   # actually remove
#   ./local-uninstall.sh              # dry run
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
info()   { echo -e "${CYAN}➜${NC} $*"; }
ok()     { echo -e "${GREEN}✔${NC} $*"; }
warn()   { echo -e "${YELLOW}⚠${NC} $*"; }
error()  { echo -e "${RED}✖${NC} $*" >&2; }
step()   { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }

AGENTS=(agent-architect agent-pm agent-lead agent-senior agent-junior agent-sdet)

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) error "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  error "Must run as root (use sudo)."
  exit 1
fi

step "What will be removed"
echo "  Services:   gitea, opencode-webhook-receiver, opencode-agent-daemon@*"
echo "  Users:      ${AGENTS[*]}"
echo "  Directories: /etc/gitea /var/lib/gitea /opt/opencode-office /home/agent-*"
echo "  Binaries:   /usr/local/bin/gitea"
echo ""
echo "  NOT touched: Redis, nginx, or any apt packages."
echo ""

if [ "$ASSUME_YES" -eq 0 ]; then
  echo -n "Type 'remove' to continue: "
  read -r CONFIRM
  [ "$CONFIRM" = "remove" ] || { info "Aborted."; exit 0; }
fi

step "Stopping services"
for a in "${AGENTS[@]}"; do
  systemctl disable --now "opencode-agent-daemon@$a" >/dev/null 2>&1 && ok "stopped daemon@$a"
done
systemctl disable --now opencode-webhook-receiver >/dev/null 2>&1 && ok "stopped webhook-receiver"
systemctl disable --now gitea >/dev/null 2>&1 && ok "stopped gitea"
systemctl disable --now atlantis >/dev/null 2>&1 && ok "stopped atlantis"
systemctl daemon-reload

step "Removing unit files"
rm -f /etc/systemd/system/opencode-agent-daemon@.service \
      /etc/systemd/system/opencode-webhook-receiver.service \
      /etc/systemd/system/gitea.service \
      /etc/systemd/system/atlantis.service
rm -f /etc/nginx/sites-enabled/opencode-office \
      /etc/nginx/sites-available/opencode-office
systemctl daemon-reload
ok "unit files removed"
nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null && ok "nginx reloaded"

step "Removing users and their homes"
for a in "${AGENTS[@]}"; do
  if id -u "$a" >/dev/null 2>&1; then
    # Kill anything still running as that user before removing it.
    pkill -u "$a" >/dev/null 2>&1 || true
    userdel -r "$a" >/dev/null 2>&1 && ok "removed $a" || warn "could not fully remove $a"
  fi
done
if id -u gitea >/dev/null 2>&1; then
  pkill -u gitea >/dev/null 2>&1 || true
  userdel -r gitea >/dev/null 2>&1 && ok "removed gitea"
fi
if id -u atlantis >/dev/null 2>&1; then
  userdel -r atlantis >/dev/null 2>&1 && ok "removed atlantis"
fi

step "Removing data"
rm -rf /etc/gitea /var/lib/gitea /opt/opencode-office /var/lib/atlantis
rm -f  /usr/local/bin/gitea /usr/local/bin/atlantis /usr/local/bin/tofu
rm -f  /tmp/agent-office-bootstrap.sh /tmp/agent-office-bootstrap.sh.raw
rm -rf /tmp/agent-office-local
ok "data removed"

step "Flushing AgentOffice Redis keys"
# Only delete the queues this project owns, never the whole database.
redis-cli --scan --pattern 'queue:agent-*' 2>/dev/null | while read -r k; do
  [ -n "$k" ] && redis-cli DEL "$k" >/dev/null 2>&1
done
redis-cli DEL queue:dead-letter >/dev/null 2>&1
ok "AgentOffice queues flushed"

step "Done"
info "Not removed: your terraform.tfvars (holds your keys). Delete it manually"
info "if you want a clean slate:"
echo -e "  ${BOLD}rm -f tofu/terraform.tfvars${NC}"
echo ""
info "Redis and nginx were left installed. Uninstall them only if you"
info "installed them just for AgentOffice."