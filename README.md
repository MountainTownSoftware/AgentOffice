# OpenCode Office

A semi-autonomous AI development team running on a single AWS EC2 instance — provisioned entirely with OpenTofu.

Five AI agents (Architect, Product Manager, Staff Tech Lead, Senior Developer, Junior Developer) collaborate via Gitea issues and git pull requests, each driven by [OpenCode](https://opencode.ai) with models from [OpenRouter](https://openrouter.ai).

## How It Works

```
Gitea Issue → Webhook → Redis Queue → Agent Daemon → opencode run → git push → PR → Comment
```

1. A human creates an issue in Gitea (or messages the PM Agent via Discord)
2. The webhook receiver routes it to the right agent's Redis queue
3. The agent daemon picks it up, runs `opencode run` with the issue context
4. The agent writes code, runs tests, pushes a branch, and opens a pull request
5. The agent comments on the issue with the PR link and status
6. A human reviews and merges

## Architecture

| Component | Role |
|---|---|
| **Gitea** | Git hosting + issue tracker (all communication is audited) |
| **Redis** | Per-agent work queues (BLPOP → one task at a time) |
| **OpenCode** | The AI coding agent that does the actual work |
| **OpenRouter** | Model provider (DeepSeek V4 Pro by default) |
| **Nginx** | Reverse proxy with optional Let's Encrypt HTTPS |

### Agents

| Agent | Linux User | Role |
|---|---|---|
| Architect | `agent-architect` | System design, architecture decisions |
| Product Manager | `agent-pm` | Discord → Gitea ticket creation |
| Staff Tech Lead | `agent-lead` | Triage, work assignment |
| Senior Developer | `agent-senior` | Complex implementation |
| Junior Developer | `agent-junior` | Simpler tasks |
| SDET (QA) | `agent-sdet` | Testing and quality assurance |

Each agent has its own Linux account, its own Redis queue, and runs as a systemd daemon.

## Install

The fastest way to get started is the one-command installer, which checks for missing dependencies, installs them, configures your AWS credentials and SSH key, and walks through deployment:

```bash
bash <(curl -s https://raw.githubusercontent.com/MountainTownSoftware/AgentOffice/refs/heads/main/install/mac-install.sh)
```

Linux users can use the same script via `linux-install.sh`, or the platform-agnostic form:

```bash
curl -s https://raw.githubusercontent.com/MountainTownSoftware/AgentOffice/refs/heads/main/install/install.sh | bash
```

The installer:
1. Checks for and installs `git`, `brew` (macOS), `tofu`, `awscli`, and `jq`
2. Configures AWS credentials
3. Generates an SSH key
4. Clones the repository
5. Prompts for your OpenRouter API key, Gitea admin password, domain, and Discord token
6. Runs `tofu init && tofu plan`, then offers to apply

## Manual Deploy

```bash
# 1. Clone
git clone https://github.com/MountainTownSoftware/AgentOffice.git agent-office && cd agent-office/tofu

# 2. Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/agent-office -N ""

# 3. Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OpenRouter API key and (optionally) a domain

# 4. Deploy
tofu init && tofu apply

# 5. SSH in and start agents
ssh -i ~/.ssh/agent-office ubuntu@<public-ip>
for agent in agent-architect agent-pm agent-lead agent-senior agent-junior agent-sdet; do
  sudo systemctl start opencode-agent-daemon@$agent
done
```

See [SETUP.md](SETUP.md) for full step-by-step instructions including HTTPS setup and monitoring.

## Requirements

- AWS account
- [OpenTofu](https://opentofu.org) ≥ 1.6 (or Terraform)
- [OpenRouter API key](https://openrouter.ai/keys)
- (Optional) A domain name for HTTPS via Let's Encrypt
- (Optional) A Discord bot token for the Product Manager agent

## Tech Stack

OpenTofu · Gitea · Redis · Nginx · Python · OpenCode · OpenRouter · systemd · AWS EC2 · Let's Encrypt

## License

MIT