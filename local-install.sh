#!/usr/bin/env bash
# Local (non-AWS) deploy for AgentOffice.
#
# Runs the same bootstrap as the EC2 user_data, on this machine, with no AWS
# resources at all: no VPC, no instance, no IAM role, no Secrets Manager.
# Secrets are read from terraform.tfvars (or prompted), services are managed by
# systemd, and everything is served over plain HTTP.
#
# Usage:
#   sudo ./local-install.sh          # run the install
#   ./local-install.sh --render-only # just write the script, don't run it
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
info()    { echo -e "${CYAN}➜${NC} $*"; }
success() { echo -e "${GREEN}✔${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✖${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }
prompt()  { echo -ne "${YELLOW}?${NC} $* "; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="$SCRIPT_DIR/tofu"
TFVARS="$TOFU_DIR/terraform.tfvars"

RENDER_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --render-only) RENDER_ONLY=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) error "Unknown option: $arg"; exit 1 ;;
  esac
done

# --- Preflight ---------------------------------------------------------

step "Checking this machine"

command -v tofu >/dev/null || { error "OpenTofu not found. Install from https://opentofu.org"; exit 1; }
success "tofu — $(tofu --version 2>&1 | head -1)"

command -v jq >/dev/null || { error "jq not found. Install with: sudo apt-get install -y jq"; exit 1; }
success "jq — $(jq --version)"

if [ ! -f /etc/os-release ]; then
  error "Cannot detect OS."
  exit 1
fi
. /etc/os-release
case "$ID" in
  ubuntu|debian) success "${PRETTY_NAME}" ;;
  *) warn "${PRETTY_NAME} — the bootstrap is written for Debian/Ubuntu and may need adjustments." ;;
esac

# The bootstrap installs packages, creates users, and writes /etc/systemd/system.
if [ "$(id -u)" -ne 0 ]; then
  error "Must run as root (use sudo)."
  exit 1
fi

# sudo users keep their own HOME; root has /root. Use the invoking user's home
# for the admin password file so it is easy to find.
ADMIN_HOME="${SUDO_USER:-root}"
ADMIN_HOME="$(getent passwd "$ADMIN_HOME" | cut -d: -f6)"
[ -n "$ADMIN_HOME" ] || ADMIN_HOME=/root
INVOKING_USER="${SUDO_USER:-root}"
info "Admin password will be written to ${BOLD}$ADMIN_HOME/.gitea_admin_password${NC}"

MEM_GB=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
AVAIL_GB=$(awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
info "Memory: ${MEM_GB} GB total, ${AVAIL_GB} GB available"
if awk "BEGIN{exit !($AVAIL_GB < 2.5)}"; then
  warn "Less than 2.5 GB available. Gitea (~280MB) plus each running agent"
  warn "and opencode (~270MB) will exhaust this box. Close other work first."
fi

# --- Config ------------------------------------------------------------

step "Configure"

if [ -f "$TFVARS" ]; then
  success "terraform.tfvars already exists"
  prompt "Overwrite it? [y/N] "
  read -r OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
    warn "Keeping existing terraform.tfvars."
    _skip_config=1
  fi
fi

if [ -z "$_skip_config" ]; then
  prompt "OpenRouter API key [sk-or-v1-...]: "
  read -r OR_KEY

  prompt "Gitea admin password [auto-generate]: "
  read -r GITEA_PW
  if [ -z "$GITEA_PW" ]; then
    GITEA_PW="$(openssl rand -base64 16 2>/dev/null || head -c 24 /dev/urandom | base64)"
  fi

  prompt "Discord bot token [leave blank to skip]: "
  read -r DISCORD_TOKEN

  cat > "$TFVARS" << TFEOL
# Local deploy — no AWS resources are created.
openrouter_api_key   = "$OR_KEY"
discord_bot_token    = "${DISCORD_TOKEN:-}"
gitea_admin_password = "$GITEA_PW"

project_name = "opencode-office"
gitea_version          = "1.23.6"
atlantis_version = "0.33.0"
tofu_version     = "1.9.0"

# Local box: HTTP only. Let's Encrypt cannot issue a cert for a LAN host.
domain_name       = ""
letsencrypt_email = ""

# Seed the Gitea repo from GitHub so agents have something to work on.
source_repo_url = "https://github.com/MountainTownSoftware/AgentOffice"
TFEOL
  chmod 600 "$TFVARS"
  success "terraform.tfvars written"
else
  OR_KEY="$(grep -E '^\s*openrouter_api_key\s*=' "$TFVARS" | sed -E 's/.*=\s*"(.*)".*/\1/')"
  DISCORD_TOKEN="$(grep -E '^\s*discord_bot_token\s*=' "$TFVARS" | sed -E 's/.*=\s*"(.*)".*/\1/')"
  GITEA_PW="$(grep -E '^\s*gitea_admin_password\s*=' "$TFVARS" | sed -E 's/.*=\s*"(.*)".*/\1/')"
fi

if [ -z "$GITEA_PW" ]; then
  error "No gitea_admin_password found in terraform.tfvars — cannot continue."
  exit 1
fi

# --- Render the bootstrap ----------------------------------------------

step "Render bootstrap script"

TARGET_SCRIPT="/tmp/agent-office-bootstrap.sh"

# Pass the secrets through the environment so they never land in the rendered
# script on disk. The template reads them only for a local deploy.
set -a
export OPENROUTER_API_KEY="$OR_KEY"
export DISCORD_BOT_TOKEN="$DISCORD_TOKEN"
export GITEA_ADMIN_PASSWORD="$GITEA_PW"
set +a

# Get the values the template needs from tfvars without duplicating defaults.
_tfvar() { grep -E "^\s*$1\s*=" "$TFVARS" | sed -E 's/.*=\s*"(.*)".*/\1/' | head -1; }
_v() { local v; v="$(_tfvar "$1")"; echo "${v:-$2}"; }

GITEA_VERSION="$(_v gitea_version 1.23.6)"
ATLANTIS_VERSION="$(_v atlantis_version 0.33.0)"
TOFU_VERSION="$(_v tofu_version 1.9.0)"
PROJECT_NAME="$(_v project_name opencode-office)"
SOURCE_REPO_URL="$(_v source_repo_url "")"

tofu console -chdir="$TOFU_DIR" \
  -var="gitea_admin_password=$GITEA_PW" \
  -var="openrouter_api_key=$OR_KEY" \
  -var="discord_bot_token=$DISCORD_TOKEN" \
  <<'TOFU_EOF' > "$TARGET_SCRIPT.raw" 2>/dev/null
local(
  access(var, "gitea_version", "1.23.6"),
  access(var, "atlantis_version", "0.33.0"),
  access(var, "tofu_version", "1.9.0"),
  access(var, "project_name", "opencode-office"),
  access(var, "source_repo_url", ""),
  access(var, "deploy_target", "aws"),
  access(var, "admin_home", "/home/ubuntu"),
  templatefile("${path.module}/user_data.sh.tpl", {
    gitea_version       = access(var, "gitea_version", "1.23.6"),
    domain_name         = "",
    letsencrypt_email   = "",
    agent_models        = access(var, "agent_models", {}),
    project_name        = access(var, "project_name", "opencode-office"),
    aws_region          = "local",
    source_repo_url     = access(var, "source_repo_url", ""),
    atlantis_version    = access(var, "atlantis_version", "0.33.0"),
    tofu_version        = access(var, "tofu_version", "1.9.0"),
    deploy_target       = "local",
    admin_home          = "/tmp/agent-office-local",
    openrouter_api_key  = var.openrouter_api_key,
    discord_bot_token   = var.discord_bot_token,
    gitea_admin_password = var.gitea_admin_password,
  })
)
TOFU_EOF

if [ ! -s "$TARGET_SCRIPT.raw" ]; then
  error "Failed to render the bootstrap script. Re-run without --render-only to see errors."
  rm -f "$TARGET_SCRIPT.raw"
  exit 1
fi

# tofu console emits the script between <<EOT / EOT markers as real lines
# (no escaping), so just strip the markers.
python3 - "$TARGET_SCRIPT.raw" "$TARGET_SCRIPT" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines(keepends=True)
if lines and lines[0].strip() == '<<EOT':
    lines = lines[1:]
if lines and lines[-1].strip() == 'EOT':
    lines = lines[:-1]
open(sys.argv[2], 'w').writelines(lines)
PYEOF
rm -f "$TARGET_SCRIPT.raw"
chmod +x "$TARGET_SCRIPT"

if ! bash -n "$TARGET_SCRIPT" 2>/dev/null; then
  error "Rendered script has syntax errors:"
  bash -n "$TARGET_SCRIPT"
  exit 1
fi
success "Rendered $TARGET_SCRIPT ($(wc -l < "$TARGET_SCRIPT") lines)"

grep -q 'DEPLOY_TARGET="${deploy_target}"' "$TARGET_SCRIPT" \
  || { error "Rendered script is missing the deploy_target marker — template drift?"; exit 1; }
success "deploy_target set correctly"

if [ "$RENDER_ONLY" -eq 1 ]; then
  info "Render-only. Inspect $TARGET_SCRIPT, then run it with sudo."
  exit 0
fi

# --- Run ----------------------------------------------------------------

step "Run bootstrap (this takes several minutes)"

sudo OPENROUTER_API_KEY="$OR_KEY" \
     DISCORD_BOT_TOKEN="$DISCORD_TOKEN" \
     GITEA_ADMIN_PASSWORD="$GITEA_PW" \
     bash "$TARGET_SCRIPT"

# The script renders ADMIN_HOME from the template var; point it at the real home.
HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
if [ -f "/tmp/agent-office-local/.gitea_admin_password" ]; then
  cp /tmp/agent-office-local/.gitea_admin_password "$ADMIN_HOME/.gitea_admin_password"
  chown "$INVOKING_USER" "$ADMIN_HOME/.gitea_admin_password" 2>/dev/null || true
  chmod 600 "$ADMIN_HOME/.gitea_admin_password"
fi

# --- Summary -------------------------------------------------------------

HOST_IP="${HOST_IP:-localhost}"

step "Done"
echo ""
success "AgentOffice is running locally 🎉"
echo ""
echo -e "  ${BOLD}Gitea:${NC}        http://${HOST_IP}"
echo -e "  ${BOLD}Admin:${NC}       admin"
echo -e "  ${BOLD}Password:${NC}    cat $ADMIN_HOME/.gitea_admin_password"
echo ""
echo -e "  ${BOLD}Services:${NC}"
echo -e "    systemctl status gitea nginx redis-server opencode-webhook-receiver"
echo -e "    systemctl status 'opencode-agent-daemon@*'"
echo ""
echo -e "  ${BOLD}Watch an agent:${NC}"
echo -e "    journalctl -u opencode-agent-daemon@agent-lead -f"
echo ""
echo -e "  ${BOLD}Uninstall:${NC}    sudo $SCRIPT_DIR/local-uninstall.sh"
echo ""