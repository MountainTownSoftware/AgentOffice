#!/usr/bin/env bash
set -euo pipefail

# AgentOffice — macOS / Linux install script
# Usage: bash <(curl -s https://github.com/MOuntainTownSoftware/AgentOffice/raw/main/install/install.sh)

REPO_URL="${AGENTOFFICE_REPO_URL:-https://github.com/MOuntainTownSoftware/AgentOffice}"
REPO_RAW="${REPO_URL/\/github.com/\/raw.githubusercontent.com}/main"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
info()    { echo -e "${CYAN}➜${NC} $*"; }
success() { echo -e "${GREEN}✔${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✖${NC} $*"; }
step()    { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }
prompt()  { echo -ne "${YELLOW}?${NC} $* "; }

OS="$(uname -s)"
ARCH="$(uname -m)"

# --- Helpers ----------------------------------------------------------

_command_exists() { command -v "$1" &>/dev/null; }
_brew()  { if _command_exists brew; then brew "$@"; else return 1; fi; }

_pause() {
  prompt "Press Enter to continue..."
  read -r
}

_install_brew() {
  if _command_exists brew; then return 0; fi
  warn "Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    else
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  else
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true
  fi
  success "Homebrew installed"
}

# --- Utils ------------------------------------------------------------

_get_arch() {
  case "$ARCH" in
    arm64|aarch64) echo "arm64" ;;
    x86_64)        echo "amd64" ;;
    *) error "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
}

_latest_github_release() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" | \
    grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/'
}

# --- Step functions ---------------------------------------------------

step_welcome() {
  clear 2>/dev/null || true
  echo -e "${BOLD}${CYAN}"
  echo "    █████╗  ██████╗ ███████╗███╗   ██╗████████╗"
  echo "   ██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝"
  echo "   ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   "
  echo "   ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   "
  echo "   ██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   "
  echo "   ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   "
  echo ""
  echo "          ██████╗ ███████╗███████╗██╗ ██████╗███████╗"
  echo "         ██╔═══██╗██╔════╝██╔════╝██║██╔════╝██╔════╝"
  echo "         ██║   ██║█████╗  █████╗  ██║██║     █████╗  "
  echo "         ██║   ██║██╔══╝  ██╔══╝  ██║██║     ██╔══╝  "
  echo "         ╚██████╔╝██║     ██║     ██║╚██████╗███████╗"
  echo "          ╚═════╝ ╚═╝     ╚═╝     ╚═╝ ╚═════╝╚══════╝"
  echo -e "${NC}"
  echo ""
  info "Semi-autonomous AI development team on AWS"
  info "This script will set up everything needed to deploy AgentOffice."
  echo ""
  _pause
}

step_check_deps() {
  step "Checking dependencies"
  echo ""

  # git
  if _command_exists git; then
    success "git — $(git --version)"
  else
    warn "git is not installed"
    if _brew install git; then
      success "git installed via brew"
    else
      error "Please install git manually: https://git-scm.com/downloads"
      exit 1
    fi
  fi

  # Homebrew (install if missing, since other tools may need it)
  _install_brew

  # OpenTofu
  if _command_exists tofu; then
    success "tofu — $(tofu --version 2>&1 | head -1)"
  else
    warn "OpenTofu not found"
    info "Installing OpenTofu..."
    if _brew install opentofu; then
      success "tofu installed via brew"
    else
      # Manual install
      TOFU_VER="$(_latest_github_release opentofu/opentofu)"
      TOFU_VER="${TOFU_VER:-1.9.0}"
      ARCH=$(_get_arch)
      TOFU_URL="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VER}/tofu_${TOFU_VER}_${OS,,}_${ARCH}.zip"

      if [[ "$OS" == "Darwin" ]]; then
        # macOS: use sudo to install to /usr/local/bin
        curl -sLo /tmp/tofu.zip "$TOFU_URL"
        sudo unzip -qo /tmp/tofu.zip -d /usr/local/bin/ tofu 2>/dev/null
        rm -f /tmp/tofu.zip
      else
        # Linux: use sudo
        curl -sLo /tmp/tofu.zip "$TOFU_URL"
        sudo unzip -qo /tmp/tofu.zip -d /usr/local/bin/ tofu 2>/dev/null
        rm -f /tmp/tofu.zip
      fi
      success "tofu installed manually"
    fi
  fi

  # AWS CLI
  if _command_exists aws; then
    success "aws cli — v$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)"
  else
    warn "AWS CLI not found"
    info "Installing AWS CLI..."
    if [[ "$OS" == "Darwin" ]] && _brew install awscli; then
      success "aws cli installed via brew"
    else
      curl -s "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg 2>/dev/null || \
        curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      if [ -f /tmp/AWSCLIV2.pkg ]; then
        sudo installer -pkg /tmp/AWSCLIV2.pkg -target / 2>/dev/null
        rm -f /tmp/AWSCLIV2.pkg
      elif [ -f /tmp/awscliv2.zip ]; then
        unzip -q /tmp/awscliv2.zip -d /tmp
        sudo /tmp/aws/install --update 2>/dev/null
        rm -rf /tmp/awscliv2.zip /tmp/aws
      fi
      success "aws cli installed"
    fi
  fi

  # jq
  if _command_exists jq; then
    success "jq — $(jq --version)"
  else
    warn "jq not found"
    if _brew install jq; then
      success "jq installed via brew"
    elif [[ "$OS" == "Linux" ]]; then
      sudo apt-get update -qq && sudo apt-get install -y -qq jq 2>/dev/null || true
      if _command_exists jq; then success "jq installed"; fi
    else
      warn "Please install jq: https://stedolan.github.io/jq/"
    fi
  fi

  # ssh-keygen
  if _command_exists ssh-keygen; then
    success "ssh-keygen — available"
  else
    warn "ssh-keygen not found (should be built-in on macOS/Linux)"
  fi

  echo ""
  success "All dependencies checked"
  _pause
}

step_aws_config() {
  step "AWS credentials"

  if aws sts get-caller-identity &>/dev/null; then
    IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
    success "AWS authenticated — ${IDENTITY}"
    prompt "Skip AWS config? [Y/n] "
    read -r SKIP
    if [[ ! "$SKIP" =~ ^[Nn] ]]; then return 0; fi
  fi

  echo ""
  info "You need AWS credentials configured."
  info "If you haven't already, run:"
  echo -e "  ${BOLD}aws configure${NC}"
  echo ""
  info "You'll need:"
  echo "  - AWS Access Key ID"
  echo "  - AWS Secret Access Key"
  echo "  - Default region (e.g. us-east-1)"
  echo ""
  prompt "Open aws configure now? [Y/n] "
  read -r DO_CONFIGURE
  if [[ ! "$DO_CONFIGURE" =~ ^[Nn] ]]; then
    aws configure
    success "AWS configured"
  else
    warn "Skipping AWS config — you'll need to configure it before deploying"
  fi
  _pause
}

step_ssh_key() {
  step "SSH key"

  local KEY_PATH="${HOME}/.ssh/agent-office"
  if [ -f "$KEY_PATH" ]; then
    success "SSH key already exists: $KEY_PATH"
    prompt "Generate a new one? [y/N] "
    read -r REGEN
    if [[ ! "$REGEN" =~ ^[Yy] ]]; then return 0; fi
    rm -f "$KEY_PATH" "$KEY_PATH.pub"
  fi

  info "Generating SSH key pair..."
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "agent-office"
  success "SSH key created: $KEY_PATH"
  echo ""
  info "Public key:"
  cat "$KEY_PATH.pub"
  echo ""
  _pause
}

step_clone_repo() {
  step "Clone the AgentOffice repository"

  prompt "Directory to clone into [./agent-office]: "
  read -r CLONE_DIR
  CLONE_DIR="${CLONE_DIR:-./agent-office}"

  if [ -d "$CLONE_DIR" ]; then
    warn "$CLONE_DIR already exists"
    prompt "Remove and re-clone? [y/N] "
    read -r RECLONE
    if [[ "$RECLONE" =~ ^[Yy] ]]; then rm -rf "$CLONE_DIR"; else return 0; fi
  fi

  git clone "$REPO_URL" "$CLONE_DIR"
  cd "$CLONE_DIR"
  success "Repository cloned to $CLONE_DIR"
  _pause
}

step_configure() {
  step "Configure terraform.tfvars"

  if [ -f terraform.tfvars ]; then
    success "terraform.tfvars already exists"
    prompt "Overwrite? [y/N] "
    read -r OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then return 0; fi
  fi

  echo ""

  # OpenRouter API key
  prompt "OpenRouter API key [sk-or-v1-...]: "
  read -r OR_KEY

  # Gitea admin password
  prompt "Gitea admin password [auto-generate]: "
  read -r GITEA_PW
  GITEA_PW="${GITEA_PW:-$(openssl rand -base64 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_urlsafe(16))' 2>/dev/null || echo 'changeme123')}"

  # Domain (optional)
  prompt "Domain name for HTTPS [leave blank for IP-only]: "
  read -r DOMAIN_NAME

  LE_EMAIL=""
  if [ -n "$DOMAIN_NAME" ]; then
    prompt "Let's Encrypt email [required for HTTPS]: "
    read -r LE_EMAIL
  fi

  # Discord (optional)
  prompt "Discord bot token [leave blank to skip]: "
  read -r DISCORD_TOKEN

  # VPC name
  prompt "VPC name [agentoffice]: "
  read -r VPC_NAME
  VPC_NAME="${VPC_NAME:-agentoffice}"

  # Write terraform.tfvars
  cat > terraform.tfvars << TFEOL
# AWS
aws_region    = "$(aws configure get region 2>/dev/null || echo 'us-east-1')"
instance_type = "t2.micro"

# VPC
vpc_name      = "$VPC_NAME"
vpc_cidr      = "10.0.0.0/16"
subnet_cidr   = "10.0.1.0/24"

# SSH
key_name             = "agent-office"
ssh_public_key_path  = "~/.ssh/agent-office.pub"

# Gitea
gitea_version          = "1.23.6"
gitea_admin_password   = "$GITEA_PW"

# Atlantis + OpenTofu
atlantis_version = "0.33.0"
tofu_version     = "1.9.0"

# API keys
openrouter_api_key = "$OR_KEY"
discord_bot_token  = "${DISCORD_TOKEN:-}"

# Domain (optional)
domain_name       = "${DOMAIN_NAME:-}"
letsencrypt_email = "${LE_EMAIL:-}"
TFEOL

  success "terraform.tfvars created"
  echo ""
  info "Config saved. You can edit terraform.tfvars at any time."
  _pause
}

step_deploy() {
  step "Deploy"

  if [ ! -f terraform.tfvars ]; then
    error "terraform.tfvars not found — run configure step first"
    return 1
  fi

  info "Initializing OpenTofu..."
  tofu init

  echo ""
  info "Planning changes..."
  tofu plan

  echo ""
  prompt "Apply these changes? [y/N] "
  read -r DO_APPLY
  if [[ "$DO_APPLY" =~ ^[Yy] ]]; then
    tofu apply -auto-approve
    success "Deployment started!"
    echo ""
    info "Instance is bootstrapping (takes ~5-7 minutes)."
    info "SSH in once ready:"
    echo "  ${BOLD}ssh -i ~/.ssh/agent-office ubuntu@\$(tofu output -raw instance_public_ip)${NC}"
    echo ""
    info "Then start the agents:"
    echo "  ${BOLD}for agent in agent-architect agent-pm agent-lead agent-senior agent-junior agent-sdet; do"
    echo "    sudo systemctl start opencode-agent-daemon@\$agent"
    echo "  done${NC}"
  else
    info "To deploy later, run: ${BOLD}cd $(pwd) && tofu apply${NC}"
  fi
}

# --- Main -------------------------------------------------------------

main() {
  step_welcome

  step_check_deps
  step_aws_config
  step_ssh_key

  # If we're already in the project directory, skip clone
  if [ -f "main.tf" ] || [ -f "tofu/main.tf" ]; then
    success "Already in AgentOffice directory — skipping clone"
    # Ensure we're in the tofu directory
    [ -d tofu ] && cd tofu
  else
    step_clone_repo
    [ -d tofu ] && cd tofu
  fi

  step_configure
  step_deploy

  echo ""
  success "Setup complete! 🎉"
  echo ""
}

main "$@"