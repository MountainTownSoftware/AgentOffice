# OpenCode Office — Setup Guide

Semi-autonomous AI development team on a single AWS EC2 instance.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    EC2 Instance                      │
│  ┌──────────┐  ┌───────┐  ┌──────────────────────┐ │
│  │  Nginx   │  │ Redis │  │  Webhook Receiver     │ │
│  │  :80     │  │ :6379 │  │  :9090 (internal)    │ │
│  └────┬─────┘  └───┬───┘  └──────────┬───────────┘ │
│       │             │                 │              │
│  ┌────▼─────┐  ┌────▼─────────────────▼──────────┐  │
│  │  Gitea   │  │       Agent Daemons              │  │
│  │  :3000   │  │  architect pm lead senior junior │  │
│  │  (git +  │  │  (systemd per-agent services)    │  │
│  │  issues) │  │  opencode run → git → PR → issue │  │
│  └──────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS account** with billing enabled
2. **OpenTofu** or **Terraform** ≥ 1.6 installed locally
3. **AWS CLI** configured (`aws configure`)
4. **OpenRouter API key** ([openrouter.ai/keys](https://openrouter.ai/keys))
5. **SSH key pair** for EC2 access
6. (Optional) **Discord bot token** for the Product Manager agent ([discord.com/developers](https://discord.com/developers/applications))

## Step 1: Clone and Configure

```bash
git clone <this-repo> opencode-office
cd opencode-office
```

### Generate SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/agent-office -N ""
```

### Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
openrouter_api_key = "sk-or-v1-your-actual-key"
# Optional:
discord_bot_token   = "your-discord-bot-token"
```

## Step 2: Deploy with OpenTofu

```bash
# Initialize
tofu init

# Preview
tofu plan

# Deploy (~5 min)
tofu apply -auto-approve
```

Wait for the instance to finish bootstrapping (check `/var/log/cloud-init-output.log` on the instance).

## Step 3: Configure Gitea Webhook

1. Open Gitea in your browser using the IP from `tofu output instance_public_ip`
2. Log in as `admin` with the password from `/home/ubuntu/.gitea_admin_password`
3. Create a repository (or use the auto-created `opencode-office`)
4. Go to **Repository Settings → Webhooks → Add Webhook (Gitea)**
5. Configure:
   - **Target URL:** `http://<PUBLIC_IP>/webhook`
   - **HTTP Method:** POST
   - **Trigger On:** Issues, Issue Comments, Pull Requests
6. Click **Add Webhook**

## Step 4: Add Agents as Collaborators

In the repository: **Settings → Collaborators → Add Collaborator**

Add each agent account: `agent-architect`, `agent-pm`, `agent-lead`, `agent-senior`, `agent-junior`

## Step 5: Start Agent Daemons

SSH into the instance:

```bash
ssh -i ~/.ssh/agent-office ubuntu@<PUBLIC_IP>
```

Start all agents:

```bash
for agent in agent-architect agent-pm agent-lead agent-senior agent-junior agent-sdet; do
  sudo systemctl start opencode-agent-daemon@$agent
done
```

Check status:

```bash
sudo systemctl status opencode-agent-daemon@agent-architect
sudo systemctl status opencode-agent-daemon@agent-pm
sudo systemctl status opencode-agent-daemon@agent-lead
sudo systemctl status opencode-agent-daemon@agent-senior
sudo systemctl status opencode-agent-daemon@agent-junior
```

## Step 6: Create Your First Ticket

In Gitea, create a new issue in your repository. Assign it to `agent-lead` for triage. The Staff Tech Lead will assess complexity and assign it to either the Junior or Senior developer.

### Feature request via Discord (if configured)

Message the Discord bot and the Product Manager agent will create a Gitea issue from your message.

## Daily Usage

### Agent workflow

1. Human creates issue in Gitea or submits request via Discord
2. Webhook routes to the appropriate agent's Redis queue
3. Agent daemon picks up the work item via `BLPOP`
4. Runs `opencode run` with the issue context
5. Implements code, runs tests, creates PR
6. Comments on the issue with status

All PRs require human review and approval before merging. Atlantis can be configured for automated plan/apply on approved PRs.

### Manual triggers

Push directly to an agent's queue:

```bash
redis-cli RPUSH queue:agent-lead '{"event":"manual","issue_number":1,"issue_title":"Refactor auth module","repo":"admin/opencode-office"}'
```

## Monitoring

### Queue depth

```bash
redis-cli LLEN queue:agent-architect
redis-cli LLEN queue:agent-pm
redis-cli LLEN queue:agent-lead
redis-cli LLEN queue:agent-senior
redis-cli LLEN queue:agent-junior
redis-cli LLEN queue:dead-letter
```

### Agent logs

```bash
sudo journalctl -u opencode-agent-daemon@agent-architect -f
sudo journalctl -u opencode-agent-daemon@agent-lead -n 50
```

### Failed items (dead letter queue)

```bash
redis-cli LRANGE queue:dead-letter 0 -1 | jq
```

### Service status

```bash
sudo systemctl status gitea redis-server nginx opencode-webhook-receiver
```

## File Layout on Instance

```
/opt/opencode-office/
├── webhook-receiver.py      # Gitea webhook → Redis queue
└── agent-daemon.py          # Agent execution loop

/home/<agent>/
├── work/                     # Git worktree for the agent
├── .agent-env                # Environment variables
├── .gitea_password           # Gitea login password
├── .gitea_token              # Gitea API token
└── .config/opencode/
    └── config.json           # OpenCode config (model, API key)

/etc/gitea/app.ini           # Gitea configuration
/var/lib/gitea/              # Gitea data directory
```

## Environment Variables Per Agent

Each agent's `/home/<agent>/.agent-env`:

- `AGENT_USER` — agent linux username
- `AGENT_MODEL` — OpenRouter model (e.g. `openrouter/deepseek/deepseek-v4-pro`)
- `GITEA_URL` — Gitea base URL
- `OPENROUTER_API_KEY` — OpenRouter API key
- `AGENT_TIMEOUT` — max opencode run time in seconds
- `GIT_REPO` — repo to pull/clone (e.g. `admin/opencode-office`)

## Costs

| Resource | Estimated Monthly |
|----------|-----------------|
| EC2 t2.micro (free tier) | $0 |
| EIP (attached) | $0 |
| 30GB gp3 EBS | ~$2.40 |
| **Total** | **~$2.40/m** |

If free tier is exhausted, add ~$8.50/mo for t2.micro.

## Troubleshooting

### Agent not picking up work
```bash
# Check queue is not empty
redis-cli LLEN queue:agent-lead

# Check daemon running
sudo systemctl status opencode-agent-daemon@agent-lead

# Check daemon logs
sudo journalctl -u opencode-agent-daemon@agent-lead | tail -20
```

### OpenCode fails

```bash
# Check opencode is installed
su - agent-lead -c 'which opencode'

# Test opencode manually
su - agent-lead -c 'opencode run "Print hello"'
```

### Webhook not firing

```bash
# Check receiver running
sudo systemctl status opencode-webhook-receiver

# Test manually
curl -X POST http://localhost:9090/ \
  -H "Content-Type: application/json" \
  -H "X-Gitea-Event: issues" \
  -d '{"action":"opened","issue":{"number":1,"title":"test"}}'

# View receiver logs
sudo journalctl -u opencode-webhook-receiver -f
```

### Reset everything

```bash
tofu destroy -auto-approve
tofu apply -auto-approve
```

## Agent Roles Reference

| Agent | Linux User | Redis Queue | Responsibility |
|-------|-----------|-------------|----------------|
| Architect | agent-architect | queue:agent-architect | System design, architecture PRs |
| Product Manager | agent-pm | queue:agent-pm | Feature requests via Discord, ticket creation |
| Staff Tech Lead | agent-lead | queue:agent-lead | Triage, work assignment |
| Senior Developer | agent-senior | queue:agent-senior | Complex implementation |
| Junior Developer | agent-junior | queue:agent-junior | Simpler tasks |
| SDET (QA) | agent-sdet | queue:agent-sdet | Testing and quality assurance |

## Adding New Agents

1. Add the agent to `variables.tf` under `agent_models`
2. Add entry in `user_data.sh.tpl` AGENT_USERS array
3. Run `tofu plan && tofu apply`
4. Add Gitea user and collaborator
5. Start the daemon: `systemctl start opencode-agent-daemon@agent-new`