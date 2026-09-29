#!/bin/bash
set -euo pipefail
echo "=== OpenCode Office Bootstrap — $(date) ==="

# Non-secret Terraform-injected values
GITEA_VERSION="${gitea_version}"
DOMAIN_NAME="${domain_name}"
LETSENCRYPT_EMAIL="${letsencrypt_email}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
SOURCE_REPO_URL="${source_repo_url}"
ATLANTIS_VERSION="${atlantis_version}"
TOFU_VERSION="${tofu_version}"
MODEL_ARCHITECT="${agent_models["architect"]}"
MODEL_PM="${agent_models["product_manager"]}"
MODEL_LEAD="${agent_models["staff_tech_lead"]}"
MODEL_SENIOR="${agent_models["senior_developer"]}"
MODEL_JUNIOR="${agent_models["junior_developer"]}"
MODEL_SDET="${agent_models["sdet"]}"

################################################
# Secrets — read from AWS Secrets Manager
################################################
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unzip curl jq

# Install AWS CLI v2
if ! command -v aws >/dev/null 2>&1; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update 2>&1 | tail -1 || true
fi

SECRETS_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "${project_name}-secrets" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text 2>/dev/null || echo '{}')

OPENROUTER_API_KEY=$(echo "$SECRETS_JSON" | jq -r '.openrouter_api_key // empty')
DISCORD_BOT_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.discord_bot_token // empty')
GITEA_ADMIN_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.gitea_admin_password // empty')

if [ -z "$GITEA_ADMIN_PASSWORD" ]; then
  echo "ERROR: Failed to read secrets from AWS Secrets Manager" >&2
  exit 1
fi

################################################
# Base packages
################################################
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git nginx redis-server python3 python3-pip \
  python3-redis python3-requests curl unzip jq sqlite3 build-essential certbot python3-certbot-nginx

systemctl enable redis-server && systemctl start redis-server

################################################
# Gitea
################################################
id -u gitea >/dev/null 2>&1 || adduser --system --group --home /var/lib/gitea --shell /bin/bash gitea

wget -q "https://dl.gitea.com/gitea/$${GITEA_VERSION}/gitea-$${GITEA_VERSION}-linux-amd64" -O /usr/local/bin/gitea
chmod +x /usr/local/bin/gitea
setcap cap_net_bind_service=+ep /usr/local/bin/gitea

mkdir -p /var/lib/gitea/{custom,data,log}
chown -R gitea:gitea /var/lib/gitea
chmod 750 /var/lib/gitea

cat > /etc/systemd/system/gitea.service << 'GITEAUNIT'
[Unit]
Description=Gitea
After=network.target redis-server.service
[Service]
Type=simple
User=gitea
Group=gitea
WorkingDirectory=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=gitea HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea
[Install]
WantedBy=multi-user.target
GITEAUNIT

mkdir -p /etc/gitea
GITEA_SECRET=$(openssl rand -hex 32)

if [ -n "$DOMAIN_NAME" ]; then
  GITEA_DOMAIN="$DOMAIN_NAME"
  GITEA_ROOT_URL="https://$DOMAIN_NAME/"
else
  GITEA_DOMAIN="localhost"
  GITEA_ROOT_URL="http://localhost:3000/"
fi

cat > /etc/gitea/app.ini << INIEOF
APP_NAME = OpenCode Office
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /var/lib/gitea/data/repos

[server]
DOMAIN = $GITEA_DOMAIN
SSH_DOMAIN = $GITEA_DOMAIN
HTTP_PORT = 3000
ROOT_URL = $GITEA_ROOT_URL
LANDING_PAGE = explore
DISABLE_SSH = false
START_SSH_SERVER = true

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db

[session]
PROVIDER = db

[log]
MODE = file
ROOT_PATH = /var/lib/gitea/log
LEVEL = Info

[security]
INSTALL_LOCK = true
SECRET_KEY = $GITEA_SECRET

[service]
DISABLE_REGISTRATION = false
REGISTER_EMAIL_CONFIRM = false
ENABLE_NOTIFY_MAIL = false

[webhook]
ALLOWED_HOST_LIST = localhost,127.0.0.1
INIEOF

chown gitea:gitea /etc/gitea/app.ini
chmod 640 /etc/gitea/app.ini

systemctl daemon-reload
systemctl enable gitea && systemctl restart gitea
sleep 5

ADMIN_PW="$GITEA_ADMIN_PASSWORD"
echo "$ADMIN_PW" > /home/ubuntu/.gitea_admin_password
chmod 600 /home/ubuntu/.gitea_admin_password

sudo -u gitea GITEA_WORK_DIR=/var/lib/gitea /usr/local/bin/gitea admin user create \
  --admin --username admin --password "$ADMIN_PW" \
  --email admin@opencode.office.local --must-change-password=false \
  --config /etc/gitea/app.ini 2>/dev/null || true

################################################
# Agent accounts
################################################
AGENT_DIR=/opt/opencode-office
mkdir -p "$AGENT_DIR"

declare -A AGENT_MODEL_MAP
AGENT_MODEL_MAP[agent-architect]="$MODEL_ARCHITECT"
AGENT_MODEL_MAP[agent-pm]="$MODEL_PM"
AGENT_MODEL_MAP[agent-lead]="$MODEL_LEAD"
AGENT_MODEL_MAP[agent-senior]="$MODEL_SENIOR"
AGENT_MODEL_MAP[agent-junior]="$MODEL_JUNIOR"
AGENT_MODEL_MAP[agent-sdet]="$MODEL_SDET"

declare -A AGENT_DISPLAY
AGENT_DISPLAY[agent-architect]="Architect Agent"
AGENT_DISPLAY[agent-pm]="Product Manager"
AGENT_DISPLAY[agent-lead]="Staff Tech Lead"
AGENT_DISPLAY[agent-senior]="Senior Developer"
AGENT_DISPLAY[agent-junior]="Junior Developer"
AGENT_DISPLAY[agent-sdet]="SDET (QA)"

AGENT_USERS=("agent-architect" "agent-pm" "agent-lead" "agent-senior" "agent-junior" "agent-sdet")

for username in "$${AGENT_USERS[@]}"; do
  if ! id -u "$username" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$username"
    echo "$${username}:$(openssl rand -base64 16)" | chpasswd
  fi
  mkdir -p "/home/$${username}/work"
  chown "$${username}:$${username}" "/home/$${username}/work"

  AGENT_PW=$(openssl rand -base64 16)
  sudo -u gitea GITEA_WORK_DIR=/var/lib/gitea /usr/local/bin/gitea admin user create \
    --username "$username" --password "$AGENT_PW" \
    --email "$${username}@opencode.office.local" --must-change-password=false \
    --config /etc/gitea/app.ini 2>/dev/null || true

  echo "$AGENT_PW" > "/home/$${username}/.gitea_password"
  chown "$${username}:$${username}" "/home/$${username}/.gitea_password"
  chmod 600 "/home/$${username}/.gitea_password"

  # API token
  sleep 1
  TOKEN_RESP=$(curl -s -X POST "http://localhost:3000/api/v1/users/$username/tokens" \
    -u "$username:$AGENT_PW" \
    -H "Content-Type: application/json" \
    -d '{"name":"agent-daemon","scopes":["read:repository","write:repository","write:issue","read:issue","write:user"]}' 2>/dev/null || echo '{}')
  GITEA_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.sha1 // empty')
  if [ -n "$GITEA_TOKEN" ]; then
    echo "$GITEA_TOKEN" > "/home/$${username}/.gitea_token"
    chown "$${username}:$${username}" "/home/$${username}/.gitea_token"
    chmod 600 "/home/$${username}/.gitea_token"
  fi

  # Agent env file
  cat > "/home/$${username}/.agent-env" << ENVFILE
AGENT_USER=$username
AGENT_MODEL=$${AGENT_MODEL_MAP[$username]}
AGENT_ROLE=$${AGENT_DISPLAY[$username]}
GITEA_URL=http://localhost:3000
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
AGENT_TIMEOUT=1800
GIT_REPO=admin/agent-office-tofu
ENVFILE
  chown "$${username}:$${username}" "/home/$${username}/.agent-env"
  chmod 600 "/home/$${username}/.agent-env"
done

################################################
# OpenCode CLI
################################################
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g @opencode/cli 2>/dev/null || true

for username in "$${AGENT_USERS[@]}"; do
  su - "$username" -c 'curl -fsSL https://opencode.ai/v2/install | bash' 2>/dev/null || true
  mkdir -p "/home/$${username}/.config/opencode"
  chown "$${username}:$${username}" "/home/$${username}/.config/opencode"
done

# Write OpenCode config for each agent
for username in "$${AGENT_USERS[@]}"; do
  OCCONF="/home/$${username}/.config/opencode/config.json"
  echo "{\"providers\":{\"openrouter\":{\"api_key\":\"$OPENROUTER_API_KEY\"}},\"default_model\":\"$${AGENT_MODEL_MAP[$username]}\"}" > "$OCCONF"
  chown "$${username}:$${username}" "$OCCONF"
  chmod 600 "$OCCONF"
done

################################################
# Webhook receiver
################################################

cat > "$AGENT_DIR/webhook-receiver.py" << 'PYEOF'
#!/usr/bin/env python3
import json, logging, os, redis, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

r = redis.Redis(host=os.environ.get('REDIS_HOST','localhost'),
                port=int(os.environ.get('REDIS_PORT',6379)), decode_responses=True)

AGENT_MAP = {
    'agent-architect':'queue:agent-architect','agent-pm':'queue:agent-pm',
    'agent-lead':'queue:agent-lead','agent-senior':'queue:agent-senior',
    'agent-junior':'queue:agent-junior','agent-sdet':'queue:agent-sdet',
}

def route(event_type, payload):
    queues = set()
    if event_type == 'issues':
        action = payload.get('action','')
        assignees = [a.get('username','') for a in (payload.get('issue',{}).get('assignees') or [])]
        if action == 'opened':
            targets = assignees if assignees else ['agent-lead']
            for t in targets:
                if t in AGENT_MAP: queues.add(AGENT_MAP[t])
        elif action in ('assigned','labeled'):
            for a in assignees:
                if a in AGENT_MAP: queues.add(AGENT_MAP[a])
    elif event_type == 'issue_comment':
        assignees = [a.get('username','') for a in (payload.get('issue',{}).get('assignees') or [])]
        comment_user = payload.get('comment',{}).get('user',{}).get('username','')
        for a in assignees:
            if a in AGENT_MAP and a != comment_user: queues.add(AGENT_MAP[a])
        if comment_user not in AGENT_MAP:
            for a in assignees:
                if a in AGENT_MAP: queues.add(AGENT_MAP[a])
    return list(queues)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length',0)))
        evt = self.headers.get('X-Gitea-Event','')
        log.info("webhook: %s", evt)
        try:
            payload = json.loads(body)
            for q in route(evt, payload):
                item = json.dumps({
                    'event':evt, 'action':payload.get('action',''),
                    'issue_number':payload.get('issue',{}).get('number'),
                    'issue_title':payload.get('issue',{}).get('title',''),
                    'issue_url':payload.get('issue',{}).get('html_url',''),
                    'issue_body':payload.get('issue',{}).get('body',''),
                    'comment':payload.get('comment',{}).get('body',''),
                    'comment_user':payload.get('comment',{}).get('user',{}).get('username',''),
                    'repo':payload.get('repository',{}).get('full_name',''),
                })
                r.rpush(q, item)
                log.info("queued -> %s", q)
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status':'ok','queued':len(queues)}).encode())
        except Exception as e:
            log.error("error: %s", e)
            self.send_response(500); self.end_headers()
    def log_message(self, f, *a): log.info("http %s", a[0] if a else f)

if __name__ == '__main__':
    port = int(os.environ.get('PORT',9090))
    HTTPServer(('127.0.0.1',port), Handler).serve_forever()
PYEOF

chmod +x "$AGENT_DIR/webhook-receiver.py"

cat > /etc/systemd/system/opencode-webhook-receiver.service << 'SVC'
[Unit]
Description=OpenCode Webhook Receiver
After=network.target redis-server.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/opencode-office/webhook-receiver.py
Restart=always
RestartSec=5
Environment=PORT=9090 REDIS_HOST=localhost REDIS_PORT=6379
[Install]
WantedBy=multi-user.target
SVC

################################################
# Agent daemon
################################################

cat > "$AGENT_DIR/agent-daemon.py" << 'PYEOF'
#!/usr/bin/env python3
import json, logging, os, subprocess, sys, time, redis

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

USER = os.environ.get('AGENT_USER','')
if not USER: sys.exit(1)

Q = f"queue:{USER}"
DLQ = "queue:dead-letter"
r = redis.Redis(host=os.environ.get('REDIS_HOST','localhost'),
                port=int(os.environ.get('REDIS_PORT',6379)), decode_responses=True)
WORKDIR = f'/home/{USER}/work'
GITEA = os.environ.get('GITEA_URL','http://localhost:3000')
API = f"{GITEA}/api/v1"
REPO = os.environ.get('GIT_REPO','admin/agent-office-tofu')
MODEL = os.environ.get('AGENT_MODEL','openrouter/deepseek/deepseek-v4-pro')
TIMEOUT = int(os.environ.get('AGENT_TIMEOUT','1800'))

def token():
    p = f'/home/{USER}/.gitea_token'
    if os.path.exists(p):
        with open(p) as f: return f.read().strip()
    return ''

TOK = token()
AUTH = ['-H',f'Authorization: token {TOK}'] if TOK else []

def api(method, path, data=None):
    cmd = ['curl','-s','-X',method,*AUTH,'-H','Content-Type: application/json',f'{API}{path}']
    if data: cmd.extend(['-d',json.dumps(data)])
    try:
        rv = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return json.loads(rv.stdout) if rv.stdout.strip() else {}
    except: return {}

def comment(owner, repo, num, body):
    return api('POST', f'/repos/{owner}/{repo}/issues/{num}/comments', {'body':body})

def run(prompt):
    env = {**os.environ, 'HOME': f'/home/{USER}'}
    try:
        rv = subprocess.run(['opencode','run',prompt], cwd=WORKDIR,
                            capture_output=True, text=True, timeout=TIMEOUT, env=env)
        return rv.returncode == 0, rv.stdout + '\n' + rv.stderr
    except subprocess.TimeoutExpired:
        return False, "timed out"
    except Exception as e:
        return False, str(e)

def process(data_str):
    try: item = json.loads(data_str)
    except: r.rpush(DLQ, f"BAD_JSON:{data_str[:500]}"); return

    num = item.get('issue_number')
    title = item.get('issue_title','Untitled')
    body = item.get('issue_body','')
    cmt = item.get('comment','')
    rep = item.get('repo', REPO)

    if '/' not in rep: return
    owner, repo = rep.split('/',1)
    ref = f"#{num}" if num else ""

    prompt = f"""You are {USER}, an AI agent.
Repository: {rep}
Issue {ref}: {title}
{body}

{f'Comment: {cmt}' if cmt else ''}

Steps:
1. git checkout main && git pull
2. Create branch: feature/{USER}-issue-{num}
3. Implement the changes
4. Run tests; if they fail, fix and re-run
5. git push origin feature/{USER}-issue-{num}
6. Create a pull request to main
7. Summarize what you did"""

    ok, out = run(prompt)
    summary = out[:3000]
    st = "completed" if ok else "failed"

    if num:
        msg = f"Task **{st}**.\n<details><summary>Output</summary>\n\n```\n{summary}\n```\n</details>"
        comment(owner, repo, num, msg)

    if not ok:
        r.rpush(DLQ, json.dumps({'agent':USER,'item':item,'output':summary,'ts':time.time()}))

def main():
    log.info("Agent %s starting, queue=%s", USER, Q)
    while True:
        try:
            v = r.blpop(Q, timeout=10)
            if v: process(v[1])
        except redis.ConnectionError:
            log.error("redis lost"); time.sleep(5)
        except Exception as e:
            log.error("err: %s", e); time.sleep(10)

if __name__ == '__main__': main()
PYEOF

chmod +x "$AGENT_DIR/agent-daemon.py"

cat > /etc/systemd/system/opencode-agent-daemon@.service << 'SVCUNIT'
[Unit]
Description=OpenCode Agent Daemon: %I
After=network.target redis-server.service
[Service]
Type=simple
User=%I
Group=%I
WorkingDirectory=/home/%I/work
ExecStart=/usr/bin/python3 /opt/opencode-office/agent-daemon.py
Restart=always
RestartSec=10
EnvironmentFile=/home/%I/.agent-env
[Install]
WantedBy=multi-user.target
SVCUNIT

################################################
# Nginx
################################################

cat > /etc/nginx/sites-available/opencode-office << 'NGINX'
server {
    listen 80 default_server;
    server_name _;

    location /atlantis {
        proxy_pass http://127.0.0.1:4141;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /webhook {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Gitea-Event $http_x_gitea_event;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/opencode-office /etc/nginx/sites-enabled/opencode-office
nginx -t && systemctl restart nginx

# HTTPS via Let's Encrypt
if [ -n "$DOMAIN_NAME" ] && [ -n "$LETSENCRYPT_EMAIL" ]; then
  # Replace server_name with the actual domain
  sed -i "s/server_name _;/server_name $DOMAIN_NAME;/" /etc/nginx/sites-available/opencode-office
  nginx -t && systemctl reload nginx

  certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos \
    -m "$LETSENCRYPT_EMAIL" --redirect 2>&1 || echo "certbot failed — ensure DNS points to this instance"

  systemctl reload nginx
fi

################################################
# Atlantis (OpenTofu PR automation)
################################################

# Install OpenTofu
wget -q "https://github.com/opentofu/opentofu/releases/download/v$${TOFU_VERSION}/tofu_$${TOFU_VERSION}_linux_amd64.zip" -O /tmp/tofu.zip
unzip -oq /tmp/tofu.zip -d /usr/local/bin/ tofu 2>/dev/null || unzip -q /tmp/tofu.zip -d /usr/local/bin/
chmod +x /usr/local/bin/tofu
rm -f /tmp/tofu.zip

# Install Atlantis
wget -q "https://github.com/runatlantis/atlantis/releases/download/v$${ATLANTIS_VERSION}/atlantis_linux_amd64.zip" -O /tmp/atlantis.zip
unzip -oq /tmp/atlantis.zip -d /usr/local/bin/ atlantis 2>/dev/null || unzip -q /tmp/atlantis.zip -d /usr/local/bin/
chmod +x /usr/local/bin/atlantis
rm -f /tmp/atlantis.zip

# Atlantis user
if ! id -u atlantis >/dev/null 2>&1; then
  useradd -r -m -s /bin/bash atlantis
fi
mkdir -p /var/lib/atlantis
chown -R atlantis:atlantis /var/lib/atlantis

# Create Gitea user + token for Atlantis
ATLANTIS_PW=$(openssl rand -base64 16)
sudo -u gitea GITEA_WORK_DIR=/var/lib/gitea /usr/local/bin/gitea admin user create \
  --username atlantis --password "$ATLANTIS_PW" \
  --email atlantis@opencode.office.local --must-change-password=false \
  --config /etc/gitea/app.ini 2>/dev/null || true

sleep 2
ATLANTIS_TOKEN=$(curl -sf -X POST "http://localhost:3000/api/v1/users/atlantis/tokens" \
  -u "atlantis:$ATLANTIS_PW" \
  -H "Content-Type: application/json" \
  -d '{"name":"atlantis-server","scopes":["read:repository","write:repository","read:issue","write:issue"]}' 2>/dev/null | jq -r '.sha1 // empty')
WEBHOOK_SECRET=$(openssl rand -hex 16)

# Atlantis URL (same external URL that Gitea webhooks hit)
if [ -n "$DOMAIN_NAME" ]; then
  ATLANTIS_URL="https://$DOMAIN_NAME/atlantis"
else
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  ATLANTIS_URL="http://$PUBLIC_IP/atlantis"
fi

cat > /home/atlantis/.atlantis-env << ATENV
ATLANTIS_GITEA_USER=atlantis
ATLANTIS_GITEA_TOKEN=$ATLANTIS_TOKEN
ATLANTIS_GITEA_BASE_URL=http://localhost:3000
ATLANTIS_GITEA_WEBHOOK_SECRET=$WEBHOOK_SECRET
ATLANTIS_GITEA_PAGE_SIZE=30
ATLANTIS_REPO_ALLOWLIST=admin/agent-office-tofu
ATLANTIS_PORT=4141
ATLANTIS_DATA_DIR=/var/lib/atlantis
ATLANTIS_TF_DISTRIBUTION=opentofu
ATLANTIS_DEFAULT_TF_VERSION=$TOFU_VERSION
ATLANTIS_ENABLE_POLICY_CHECKS=false
ATLANTIS_ATLANTIS_URL=$ATLANTIS_URL
ATENV
chown atlantis:atlantis /home/atlantis/.atlantis-env
chmod 600 /home/atlantis/.atlantis-env

# Register Atlantis webhook in Gitea repo (retry in case repo not yet created)
for _ in $(seq 1 12); do
  curl -sf -X POST "http://localhost:3000/api/v1/repos/admin/agent-office-tofu/hooks" \
    -u "admin:$ADMIN_PW" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"config\":{\"url\":\"$ATLANTIS_URL/events\",\"content_type\":\"json\",\"secret\":\"$WEBHOOK_SECRET\"},\"events\":[\"pull_request\"],\"active\":true}" \
    > /dev/null 2>&1 && break
  sleep 10
done

# Atlantis systemd service
cat > /etc/systemd/system/atlantis.service << 'ATUNIT'
[Unit]
Description=Atlantis
After=network.target gitea.service
Wants=gitea.service

[Service]
Type=simple
User=atlantis
Group=atlantis
EnvironmentFile=/home/atlantis/.atlantis-env
ExecStart=/usr/local/bin/atlantis server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
ATUNIT

systemctl daemon-reload
systemctl enable atlantis

################################################
# Enable services
################################################

systemctl daemon-reload
systemctl enable opencode-webhook-receiver && systemctl restart opencode-webhook-receiver

for username in "$${AGENT_USERS[@]}"; do
  systemctl enable "opencode-agent-daemon@$username"
done

################################################
# Self-host: push tofu files into AgentOffice - Tofu repo
################################################

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

if [ -n "$SOURCE_REPO_URL" ]; then
  # Wait for the "agent-office-tofu" repo (created by Terraform) to exist.
  for i in $(seq 1 60); do
    if curl -sf -u "admin:$ADMIN_PW" \
      "http://localhost:3000/api/v1/repos/admin/agent-office-tofu" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  git clone --depth 1 "$SOURCE_REPO_URL" /opt/opencode-office/tofu-src 2>/dev/null || true
  if [ -d /opt/opencode-office/tofu-src/.git ]; then
    cd /opt/opencode-office/tofu-src
    git remote remove origin 2>/dev/null || true
    git remote add origin "http://admin:$ADMIN_PW@localhost:3000/admin/agent-office-tofu.git"
    git branch -M main
    git push -u origin main 2>&1 || true
    echo "Pushed tofu files to AgentOffice - Tofu repo"
  fi
fi

################################################
echo "=== Bootstrap complete — $(date) ==="
echo ""

if [ -n "$DOMAIN_NAME" ]; then
  GITEA_URL="https://$DOMAIN_NAME"
  WEBHOOK_URL="https://$DOMAIN_NAME/webhook"
else
  GITEA_URL="http://$PUBLIC_IP"
  WEBHOOK_URL="http://$PUBLIC_IP/webhook"
fi

echo "  Gitea URL:      $GITEA_URL"
echo "  Gitea admin:    admin / $ADMIN_PW"
echo "  Admin pwd file: /home/ubuntu/.gitea_admin_password"
echo ""
echo "=== Agent Accounts ==="
for username in "$${AGENT_USERS[@]}"; do
  echo "  $username — $${AGENT_DISPLAY[$username]} — queue:queue:$username"
done
echo ""
echo "=== Post-Setup ==="
echo "1. Open Gitea: $GITEA_URL and log in as admin"
echo "2. Repo Settings > Webhooks > Add Webhook:"
echo "     URL: $WEBHOOK_URL"
echo "     Events: Issues, Issue Comments, Pull Requests"
echo "3. Add agents as collaborators to the repo"
echo "4. Start agents:"
for username in "$${AGENT_USERS[@]}"; do
  echo "     systemctl start opencode-agent-daemon@$username"
done
echo ""
systemctl is-active gitea redis-server nginx opencode-webhook-receiver 2>/dev/null || true