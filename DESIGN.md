# Overview

The goal of this project is to create a semi-autonomous work environment for open code agents to live on a single computer in AWS using OpenTofu.
All software should be open source and deployable on a single AWS EC2 instance, preferably on the free tier.

# Services

| Service | Purpose |
|---|---|
| **Gitea** | Git repository hosting + issue tracker (ticket system) |
| **Redis** | Per-agent work queues |
| **Webhook Receiver** | Receives Gitea webhooks, determines target agent, pushes to Redis |
| **OpenCode** | Agent execution — invoked by each agent's daemon |

Gitea, Redis, and the webhook receiver run as shared services. Each agent account runs its own daemon.

# Git

Git repositories hosted via Gitea. Agents create PRs; a human reviews and applies them via Atlantis.

# Atlantis

Runs in a separate Linux account, isolated from the agents. Handles `terraform apply` upon human approval.

# Communication

All inter-agent communication happens through Gitea issues. No direct agent-to-agent chat. Agent state and memory are stored entirely in Gitea (issues, comments, PR history).

# Ticket System

Gitea issues serve as the ticketing system. Workflows use issue creation, assignment, comments, and labels.

# Queueing

A shared webhook receiver accepts Gitea webhook events and pushes work items to per-agent Redis lists. Each agent runs a daemon that consumes its queue one item at a time via blocking `BLPOP`, ensuring sequential, serialized work.

# Agent Execution Model

Each agent daemon follows a simple loop:

1. `BLPOP` the next work item from its Redis queue
2. Invoke `opencode run` (or the OpenCode HTTP API) with the issue context as a prompt
3. OpenCode does the work, writes code, runs tests, commits, and creates a PR in Gitea
4. Agent comments on the Gitea issue with the PR link and status
5. Loop back to step 1

Agents run via opencode and use models in OpenRouter.

# Models

All agents default to **DeepSeek V4 Pro**. If cost optimization is needed later, the Junior Developer and Product Manager can be downgraded to a cheaper model.

| Agent | Default Model |
|---|---|
| Architect | DeepSeek V4 Pro |
| Staff Tech Lead | DeepSeek V4 Pro |
| Senior Developer | DeepSeek V4 Pro |
| Junior Developer | DeepSeek V4 Pro (tier down to DeepSeek Chat if needed) |
| Product Manager | DeepSeek V4 Pro (tier down to DeepSeek Chat if needed) |

# Testing

Agents must run tests within their OpenCode session before submitting a PR. If tests fail, the agent should fix the code and re-test.

# Monitoring

| Layer | Approach |
|---|---|
| **Work tracking** | Gitea dashboard (issues, PRs, activity) |
| **Queue health** | Redis `LLEN` checks on each agent's queue + dead letter queue for failures |
| **Agent activity** | Per-agent daemon logs (timing, success/failure per task) |
| **Process supervision** | Daemons run as systemd services (`journalctl` for logs, auto-restart) |
| **System metrics** | Netdata (optional — `apt install netdata` for auto-discovered dashboards) |

A dead letter queue in Redis holds failed work items for manual review.

# Agent Accounts

Each agent has its own Linux account and its own Redis queue.

## Architect Agent
Specializes in software architecture. Makes final recommendations on system design. Creates PRs into the OpenTofu repository.

## Product Manager
Takes feature requests via Discord (embedded Discord bot client in the daemon for real-time responses). Creates and manages Gitea tickets. Communicates back to the requestor through Discord.

## Staff Tech Lead Developer
Triages incoming tickets. Assigns work to the Junior or Senior developer depending on complexity.

## Senior Developer
Works at a senior level, using an appropriate model.

## Junior Developer
Works at a junior level, using an appropriate model.

## SDET (QA)
Specializes in testing and quality assurance. Writes and runs tests, validates agent work.