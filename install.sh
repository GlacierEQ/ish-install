#!/bin/sh
# APEX-ISH ONE-COMMAND INSTALLER
# Usage: wget -qO- https://raw.githubusercontent.com/GlacierEQ/ish-install/main/install.sh | sh

echo ""
echo "██████████████████████████████████████"
echo "  APEX-ISH INSTALLER STARTING..."
echo "  Case 1FDV-23-0001009 | GlacierEQ"
echo "██████████████████████████████████████"
echo ""

# ─── 1. Fix APK repos first ──────────────────────────────────────────────────
echo "[1/6] Fixing Alpine package repositories..."
mkdir -p /etc/apk
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.18/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.18/community\n' > /etc/apk/repositories
apk fix 2>/dev/null || true
apk update

# ─── 2. Install core packages ─────────────────────────────────────────────────
echo "[2/6] Installing core packages..."
apk add --no-cache python3 py3-pip curl wget git bash openssh util-linux

# ─── 3. Create APEX directory structure ──────────────────────────────────────
echo "[3/6] Building APEX directory structure..."
mkdir -p ~/.apex/logs
mkdir -p ~/.apex/vault
mkdir -p ~/scripts/apex-ish

# ─── 4. Write apex-ish.sh directly (no git clone needed) ─────────────────────
echo "[4/6] Writing APEX shell environment..."
cat > ~/scripts/apex-ish/apex-ish.sh << 'APEXSHELL'
#!/bin/sh
# APEX-ISH Shell v2.0 — Complete iSH integration for iPhone 16 Pro Max
export APEX_HOME="$HOME/.apex"
export APEX_REPO="$HOME/apex-connector-registry"
export CASE_ID="1FDV-23-0001009"
export NOTION_WORKSPACE_ID="506d0b07-3284-4b63-a6c9-c5583176045c"
mkdir -p "$APEX_HOME/logs"

if [ -f "$APEX_HOME/vault.env" ]; then
  set -a && . "$APEX_HOME/vault.env" && set +a
fi

apex_status() {
  echo "=== APEX STATUS ==="
  echo "Case:     $CASE_ID"
  echo "Notion:   $([ -n "$NOTIONAPIKEY" ] && echo 'KEY SET' || echo 'MISSING')"
  echo "GitHub:   $([ -n "$GITHUBTOKEN" ] && echo 'KEY SET' || echo 'MISSING')"
  echo "Vault:    $APEX_HOME/vault.env"
}

apex_heartbeat() {
  echo "[APEX] $(date) | LIVE | $CASE_ID"
  apex_status
}

apex_upload() {
  FILE="$1"
  [ -z "$FILE" ] || [ ! -f "$FILE" ] && echo "Usage: apex_upload <file>" && return 1
  CONTENT=$(base64 "$FILE" 2>/dev/null || openssl base64 -in "$FILE")
  FILENAME=$(basename "$FILE")
  curl -s -X PUT \
    -H "Authorization: token $GITHUBTOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"message\":\"upload: $FILENAME\",\"content\":\"$CONTENT\"}" \
    "https://api.github.com/repos/GlacierEQ/apex-connector-registry/contents/uploads/$FILENAME" \
    | grep -o '"html_url":"[^"]*"' | head -1
}

apex_push() {
  TYPE="$1"; DATA="$2"
  [ -z "$TYPE" ] || [ -z "$DATA" ] && echo "Usage: apex_push <type> <json>" && return 1
  if [ -n "$N8N_WEBHOOK_URL" ]; then
    curl -s -X POST "$N8N_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"type\":\"$TYPE\",\"data\":$DATA,\"case\":\"$CASE_ID\"}" && echo "[APEX] Pushed."
  else
    echo "{\"type\":\"$TYPE\",\"data\":$DATA}" >> "$APEX_HOME/push_queue.json"
    echo "[APEX] Queued locally."
  fi
}

apex_start() {
  [ ! -d "$APEX_REPO" ] && echo "[APEX] Repo not found. Run: apex_install" && return 1
  export NOTIONAPIKEY GITHUBTOKEN NOTION_WORKSPACE_ID
  nohup python3 "$APEX_REPO/server/notion_bridge.py" > /tmp/notion_bridge.log 2>&1 &
  echo "[APEX] notion_bridge started (PID=$!)"
  nohup python3 "$APEX_REPO/server/activation_orchestrator.py" > /tmp/activation_orchestrator.log 2>&1 &
  echo "[APEX] activation_orchestrator started (PID=$!)"
}

apex_stop() {
  pkill -f notion_bridge.py 2>/dev/null && echo "[APEX] notion_bridge stopped."
  pkill -f activation_orchestrator.py 2>/dev/null && echo "[APEX] orchestrator stopped."
}

apex_install() {
  echo "[APEX] Installing dependencies..."
  apk add --no-cache python3 py3-pip git curl 2>/dev/null || true
  [ ! -d "$APEX_REPO" ] && \
    git clone https://github.com/GlacierEQ/apex-connector-registry.git "$APEX_REPO" || \
    (cd "$APEX_REPO" && git pull origin main)
  pip3 install --quiet mcp notion-client python-dotenv httpx 2>/dev/null || \
    python3 -m pip install --quiet mcp notion-client python-dotenv httpx
  echo "[APEX] Install complete. Run: apex_start"
}

apex_vault_set() {
  KEY="$1"; VAL="$2"
  [ -z "$KEY" ] || [ -z "$VAL" ] && echo "Usage: apex_vault_set KEY VALUE" && return 1
  mkdir -p "$APEX_HOME"
  grep -v "^${KEY}=" "$APEX_HOME/vault.env" > /tmp/vault_tmp 2>/dev/null || true
  echo "${KEY}=${VAL}" >> /tmp/vault_tmp
  mv /tmp/vault_tmp "$APEX_HOME/vault.env"
  chmod 600 "$APEX_HOME/vault.env"
  eval "export $KEY=$VAL"
  echo "[APEX] $KEY saved to vault."
}

apex_logs() {
  echo "=== notion_bridge ==="; tail -20 /tmp/notion_bridge.log 2>/dev/null || echo "not running"
  echo "=== orchestrator ==="; tail -20 /tmp/activation_orchestrator.log 2>/dev/null || echo "not running"
}

apex_help() {
  echo "APEX iSH Commands:"
  echo "  apex_status              - show status"
  echo "  apex_heartbeat           - live ping"
  echo "  apex_install             - install deps + clone repo"
  echo "  apex_start               - start servers"
  echo "  apex_stop                - stop servers"
  echo "  apex_logs                - tail logs"
  echo "  apex_upload <file>       - upload to GitHub"
  echo "  apex_push <type> <json>  - push event"
  echo "  apex_vault_set KEY VAL   - save secret"
  echo "  apex_help                - this menu"
}

echo ""
echo "██████████████████████████████████████"
echo "  APEX LIVE | $CASE_ID"
echo "  iPhone 16 Pro Max | GlacierEQ"
echo "██████████████████████████████████████"
echo "  apex_help for all commands"
echo ""
apex_status
echo ""
APEXSHELL

chmod +x ~/scripts/apex-ish/apex-ish.sh

# ─── 5. Hook into shell profile ───────────────────────────────────────────────
echo "[5/6] Hooking into shell profile..."
PROFILE="$HOME/.profile"
grep -q 'apex-ish.sh' "$PROFILE" 2>/dev/null || \
  echo '. ~/scripts/apex-ish/apex-ish.sh' >> "$PROFILE"

# ─── 6. Done ──────────────────────────────────────────────────────────────────
echo "[6/6] Done!"
echo ""
echo "██████████████████████████████████████"
echo "  APEX-ISH INSTALL COMPLETE"
echo "  Run: source ~/.profile"
echo "  Then: apex_status"
echo "██████████████████████████████████████"
echo ""
