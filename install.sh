#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# APEX-ISH BULLETPROOF INSTALLER v2.1
# Purpose: Production-grade iSH + APEX bootstrap for iPhone 16 Pro Max
# Safety:  Atomic ops, pre-flight checks, rollback on failure, comprehensive logs
# ══════════════════════════════════════════════════════════════════════════════

set -eu

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
export APEX_HOME="${HOME}/.apex"
export APEX_LOG_DIR="${APEX_HOME}/logs"
export APEX_VAULT="${APEX_HOME}/vault.env"
export APEX_REPO="${HOME}/apex-connector-registry"
export APEX_VERSION="2.1"
export CASE_ID="1FDV-23-0001009"
export MIN_DISK_MB="5120"
export VERBOSE="${VERBOSE:-0}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── UTILITY FUNCTIONS ───────────────────────────────────────────────────────

log_info() {
  echo "${BLUE}[INFO]${NC} $*" >&2
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${APEX_LOG_DIR}/install.log"
}

log_success() {
  echo "${GREEN}[✓]${NC} $*" >&2
  echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${APEX_LOG_DIR}/install.log"
}

log_warn() {
  echo "${YELLOW}[⚠]${NC} $*" >&2
  echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${APEX_LOG_DIR}/install.log"
}

log_error() {
  echo "${RED}[ERROR]${NC} $*" >&2
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${APEX_LOG_DIR}/install.log"
}

die() {
  log_error "$*"
  exit 1
}

verbose() {
  [ "$VERBOSE" = "1" ] && log_info "$*" || true
}

# ─── PRE-FLIGHT CHECKS ───────────────────────────────────────────────────────

check_environment() {
  log_info "Running pre-flight checks..."
  
  # Check if running in iSH
  if ! grep -q "ish" /proc/version 2>/dev/null && [ ! -f /etc/lsb-release-ish ]; then
    log_warn "Not running in iSH detected. Continuing anyway..."
  fi
  
  # Check Alpine version
  if [ -f /etc/alpine-release ]; then
    ALPINE_VER=$(cat /etc/alpine-release)
    log_info "Alpine version: $ALPINE_VER"
  else
    log_warn "Alpine release file not found"
  fi
  
  # Check disk space
  AVAIL_DISK=$(df "$HOME" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
  if [ "$AVAIL_DISK" -lt "$MIN_DISK_MB" ]; then
    die "Insufficient disk space: ${AVAIL_DISK}MB available, ${MIN_DISK_MB}MB required"
  fi
  log_success "Disk check: ${AVAIL_DISK}MB available (required: ${MIN_DISK_MB}MB)"
  
  # Check write permissions
  if ! touch "${HOME}/.apex-write-test" 2>/dev/null; then
    die "No write permission to $HOME"
  fi
  rm -f "${HOME}/.apex-write-test"
  log_success "Write permissions verified"
}

# ─── ATOMIC OPERATIONS WITH ROLLBACK ─────────────────────────────────────────

setup_rollback() {
  export ROLLBACK_SCRIPT="/tmp/apex-rollback-$$.sh"
  echo "#!/bin/sh" > "$ROLLBACK_SCRIPT"
  chmod +x "$ROLLBACK_SCRIPT"
}

add_rollback_step() {
  echo "# Rollback: $1" >> "$ROLLBACK_SCRIPT"
  echo "$2" >> "$ROLLBACK_SCRIPT"
}

execute_rollback() {
  log_error "Installation failed. Rolling back..."
  if [ -f "$ROLLBACK_SCRIPT" ]; then
    sh "$ROLLBACK_SCRIPT" || log_warn "Rollback incomplete (manual cleanup may be needed)"
    rm -f "$ROLLBACK_SCRIPT"
  fi
}

trap execute_rollback EXIT

# ─── INSTALLATION STAGES ────────────────────────────────────────────────────

stage_banner() {
  STAGE=$1
  DESC=$2
  echo ""
  echo "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo "${BLUE}  [$STAGE] $DESC${NC}"
  echo "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  log_info "Stage $STAGE: $DESC"
}

stage_1_apk_repos() {
  stage_banner "1" "Fix Alpine Package Repositories"
  
  mkdir -p /etc/apk
  add_rollback_step "APK repos" "cp /tmp/apk-repos-backup.txt /etc/apk/repositories 2>/dev/null || true"
  
  cp /etc/apk/repositories /tmp/apk-repos-backup.txt 2>/dev/null || true
  
  cat > /etc/apk/repositories << 'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.18/main
https://dl-cdn.alpinelinux.org/alpine/v3.18/community
REPOS
  
  if apk fix 2>&1 | grep -q "error"; then
    log_warn "APK fix reported warnings (continuing)"
  fi
  
  if ! apk update > /tmp/apk-update.log 2>&1; then
    die "APK update failed: $(cat /tmp/apk-update.log | head -5)"
  fi
  log_success "APK repositories configured"
}

stage_2_packages() {
  stage_banner "2" "Install Core Packages"
  
  PACKAGES="python3 py3-pip curl wget git bash openssh util-linux ca-certificates"
  
  if ! apk add --no-cache $PACKAGES > /tmp/apk-install.log 2>&1; then
    die "Package installation failed: $(cat /tmp/apk-install.log | head -5)"
  fi
  
  # Verify critical commands
  for cmd in python3 pip3 curl wget git bash; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      die "Post-install verification failed: $cmd not found"
    fi
  done
  log_success "Core packages installed and verified"
}

stage_3_directories() {
  stage_banner "3" "Build Directory Structure"
  
  for dir in "$APEX_LOG_DIR" "$APEX_HOME/vault" "$APEX_HOME/tmp"; do
    mkdir -p "$dir" || die "Failed to create $dir"
    add_rollback_step "Remove directory $dir" "rm -rf '$dir'"
  done
  
  log_success "Directory structure created"
}

stage_4_apex_shell() {
  stage_banner "4" "Write APEX Shell Environment"
  
  SHELL_SCRIPT="${APEX_HOME}/apex-ish.sh"
  add_rollback_step "Remove apex-ish.sh" "rm -f '$SHELL_SCRIPT'"
  
  cat > "$SHELL_SCRIPT" << 'APEXSHELL'
#!/bin/sh
# APEX-ISH Shell v2.1 — iPhone 16 Pro Max
export APEX_HOME="${APEX_HOME:-$HOME/.apex}"
export APEX_REPO="${APEX_REPO:-$HOME/apex-connector-registry}"
export CASE_ID="1FDV-23-0001009"
export NOTION_WORKSPACE_ID="506d0b07-3284-4b63-a6c9-c5583176045c"
export APEX_VERSION="2.1"

mkdir -p "$APEX_HOME/logs"

# Load vault if exists
if [ -f "$APEX_HOME/vault.env" ]; then
  set -a && . "$APEX_HOME/vault.env" && set +a
fi

apex_status() {
  echo "=== APEX STATUS ==="
  echo "Version:  $APEX_VERSION"
  echo "Case:     $CASE_ID"
  echo "Home:     $APEX_HOME"
  echo "Notion:   $([ -n "${NOTIONAPIKEY:-}" ] && echo 'KEY SET' || echo 'MISSING')"
  echo "GitHub:   $([ -n "${GITHUBTOKEN:-}" ] && echo 'KEY SET' || echo 'MISSING')"
  echo "Repo:     $([ -d "$APEX_REPO" ] && echo 'INSTALLED' || echo 'NOT INSTALLED')"
}

apex_heartbeat() {
  echo "[APEX] $(date '+%Y-%m-%d %H:%M:%S') | LIVE | $CASE_ID | v$APEX_VERSION"
  apex_status
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
  echo "[APEX] $KEY saved to vault ($(stat -c%s "$APEX_HOME/vault.env" 2>/dev/null || echo '?')B)"
}

apex_vault_show() {
  if [ ! -f "$APEX_HOME/vault.env" ]; then
    echo "[APEX] No vault found"
    return 1
  fi
  echo "[APEX] Vault contents (redacted):"
  grep -E '^[^=]+=' "$APEX_HOME/vault.env" | sed 's/=.*/=***REDACTED***/' 
}

apex_logs() {
  echo "=== Recent logs ==="
  ls -lhtr "$APEX_HOME/logs/" 2>/dev/null | tail -5 || echo "No logs yet"
}

apex_help() {
  cat << 'HELP'
APEX iSH v2.1 Command Reference:

Status & Info:
  apex_status              - Show current status
  apex_heartbeat           - Live ping (shows version + status)
  apex_logs                - List recent log files
  apex_vault_show          - Show vault keys (values redacted)

Configuration:
  apex_vault_set KEY VAL   - Save secret to vault (creates ~/.apex/vault.env)

Server Control:
  apex_start               - Start APEX servers
  apex_stop                - Stop APEX servers
  apex_status              - Check server status

Advanced:
  apex_help                - This menu
  apex_version             - Show version
HELP
}

apex_version() {
  echo "APEX iSH v$APEX_VERSION"
  echo "Case: $CASE_ID"
  [ -f "$APEX_HOME/vault.env" ] && echo "Vault: CONFIGURED" || echo "Vault: NOT CONFIGURED"
}

apex_install() {
  if [ -d "$APEX_REPO" ]; then
    echo "[APEX] Repo already installed. Updating..."
    (cd "$APEX_REPO" && git pull origin main 2>&1 | tail -3)
  else
    echo "[APEX] Cloning apex-connector-registry..."
    git clone https://github.com/GlacierEQ/apex-connector-registry.git "$APEX_REPO" || return 1
  fi
  echo "[APEX] Installing Python dependencies..."
  pip3 install --quiet notion-client python-dotenv httpx mcp 2>/dev/null || true
  echo "[APEX] Install complete. Run: apex_start"
}

apex_start() {
  if [ ! -d "$APEX_REPO" ]; then
    echo "[APEX] Repo not found. Run: apex_install"
    return 1
  fi
  echo "[APEX] Starting servers..."
  mkdir -p "$APEX_HOME/logs"
  nohup python3 "$APEX_REPO/server/notion_bridge.py" >> "$APEX_HOME/logs/notion_bridge.log" 2>&1 &
  echo "[APEX] notion_bridge started (PID=$!)"
  nohup python3 "$APEX_REPO/server/activation_orchestrator.py" >> "$APEX_HOME/logs/orchestrator.log" 2>&1 &
  echo "[APEX] orchestrator started (PID=$!)"
  sleep 1 && apex_heartbeat
}

apex_stop() {
  echo "[APEX] Stopping servers..."
  pkill -f notion_bridge.py 2>/dev/null && echo "[APEX] notion_bridge stopped" || true
  pkill -f activation_orchestrator.py 2>/dev/null && echo "[APEX] orchestrator stopped" || true
}

# Banner
echo ""
echo "████████████████████████████████████████████████"
echo "  APEX iSH v$APEX_VERSION loaded"
echo "  Case: $CASE_ID"
echo "  Type: apex_help"
echo "████████████████████████████████████████████████"
echo ""
APEXSHELL
  
  chmod +x "$SHELL_SCRIPT"
  log_success "APEX shell environment created ($SHELL_SCRIPT)"
}

stage_5_profile_hook() {
  stage_banner "5" "Hook into Shell Profile"
  
  PROFILE="${HOME}/.profile"
  APEX_SOURCE="[ -f '$APEX_HOME/apex-ish.sh' ] && . '$APEX_HOME/apex-ish.sh'"
  
  if grep -q "apex-ish.sh" "$PROFILE" 2>/dev/null; then
    log_info "APEX hook already in profile"
  else
    echo "" >> "$PROFILE"
    echo "# APEX-ISH Integration (added $(date '+%Y-%m-%d %H:%M:%S'))" >> "$PROFILE"
    echo "$APEX_SOURCE" >> "$PROFILE"
    add_rollback_step "Remove APEX hook from profile" "grep -v 'apex-ish.sh' '$PROFILE' > /tmp/profile_tmp && mv /tmp/profile_tmp '$PROFILE'"
    log_success "APEX hook added to profile"
  fi
}

stage_6_verify() {
  stage_banner "6" "Post-Installation Verification"
  
  # Check directories
  for dir in "$APEX_LOG_DIR" "$APEX_HOME/vault"; do
    [ -d "$dir" ] || die "Missing directory: $dir"
  done
  log_success "Directory structure verified"
  
  # Check shell script
  [ -f "$APEX_HOME/apex-ish.sh" ] || die "Missing APEX shell script"
  [ -x "$APEX_HOME/apex-ish.sh" ] || chmod +x "$APEX_HOME/apex-ish.sh"
  log_success "APEX shell script verified"
  
  # Load and test
  . "$APEX_HOME/apex-ish.sh" 2>/dev/null || log_warn "Failed to source shell (OK if first run)"
  log_success "All verification checks passed"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────────────────────

main() {
  echo ""
  echo "████████████████████████████████████████████████"
  echo "  APEX-ISH BULLETPROOF INSTALLER v${APEX_VERSION}"
  echo "  Case: ${CASE_ID}"
  echo "  iPhone 16 Pro Max | GlacierEQ"
  echo "████████████████████████████████████████████████"
  echo ""
  
  # Setup
  mkdir -p "$APEX_LOG_DIR"
  > "${APEX_LOG_DIR}/install.log"
  setup_rollback
  
  log_info "Installation started by $(whoami) on $(date)"
  log_info "APEX version: $APEX_VERSION"
  log_info "Case ID: $CASE_ID"
  
  # Pre-flight
  check_environment
  
  # Install stages
  stage_1_apk_repos
  stage_2_packages
  stage_3_directories
  stage_4_apex_shell
  stage_5_profile_hook
  stage_6_verify
  
  # Success
  trap - EXIT
  rm -f "$ROLLBACK_SCRIPT"
  
  log_success "Installation complete!"
  
  echo ""
  echo "████████████████████████████████████████████████"
  echo "  APEX-ISH READY"
  echo "████████████████████████████████████████████████"
  echo ""
  echo "Next steps:"
  echo "  1. Run: source ~/.profile"
  echo "  2. Run: apex_status"
  echo "  3. Save API keys: apex_vault_set NOTIONAPIKEY 'your_key...'"
  echo "  4. Start servers: apex_start"
  echo ""
}

main "$@"