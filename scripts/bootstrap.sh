#!/usr/bin/env bash
# DeepSeek Harness (dsh) environment agent:
#   observe -> diagnose -> act -> verify (local playbook agent, not an LLM)
#
# 用法（推荐，从站点复制）:
#   curl -fsSL https://<你的站点>/scripts/bootstrap.sh | bash
#
# 本地调试:
#   ./bootstrap.sh
#   ./bootstrap.sh --check-only
#   ./bootstrap.sh --no-launch
#   ./bootstrap.sh --api-key 'sk-xxx' --base-url 'https://api.example/v1'
#   ./bootstrap.sh --max-rounds 8
#
# 环境变量覆盖:
#   DSH_ONBOARD_API_KEY, DSH_ONBOARD_BASE_URL, DSH_ONBOARD_CONFIG_URL

set -euo pipefail

# ========== 内置默认配置（部署前请改成真实值）==========
DEFAULT_API_KEY='sk-PGHkWh0C8rV1FMuQ2D4jXAtYBnSRILcz07zpQ7NR16RMYfbJ'
DEFAULT_BASE_URL='https://newapi.dapeng.uno/v1'
DEFAULT_PACKAGE='@deepseek-ai/dsh'
DEFAULT_LAUNCH_ARGS=(web)
# =====================================================

API_KEY="${DSH_ONBOARD_API_KEY:-}"
BASE_URL="${DSH_ONBOARD_BASE_URL:-}"
CONFIG_URL="${DSH_ONBOARD_CONFIG_URL:-}"
PACKAGE="$DEFAULT_PACKAGE"
LAUNCH_ARGS=("${DEFAULT_LAUNCH_ARGS[@]}")
CHECK_ONLY=0
NO_LAUNCH=0
SKIP_NODE_INSTALL=0
MAX_ROUNDS=6

step() {
  local level="${1:-info}"
  shift
  local prefix
  case "$level" in
    ok) prefix='[ OK ]' ;;
    warn) prefix='[WARN]' ;;
    err) prefix='[ERR ]' ;;
    title) prefix='[====]' ;;
    *) prefix='[ .. ]' ;;
  esac
  printf '%s %s\n' "$prefix" "$*"
}

mask_secret() {
  local v="${1:-}"
  local n=${#v}
  if [ "$n" -eq 0 ]; then
    printf '%s' '(empty)'
    return
  fi
  if [ "$n" -le 8 ]; then
    printf '%*s' "$n" '' | tr ' ' '*'
    return
  fi
  local head=${v:0:4}
  local tail=${v: -4}
  printf '%s************%s' "$head" "$tail"
}

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [options]

  --api-key KEY          DeepSeek API key
  --base-url URL         API base URL (OpenAI-compatible)
  --config-url URL       Fetch JSON config (apiKey/baseURL/cliPackage/…)
  --package NAME         npm package (default: @deepseek-ai/dsh)
  --check-only           Only verify environment
  --no-launch            Configure credentials but do not start dsh
  --skip-node-install    Do not attempt to install Node.js
  --max-rounds N         Agent loop limit (default: 6)
  -h, --help             Show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --config-url) CONFIG_URL="${2:-}"; shift 2 ;;
    --package) PACKAGE="${2:-}"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    --skip-node-install) SKIP_NODE_INSTALL=1; shift ;;
    --max-rounds) MAX_ROUNDS="${2:-6}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) step err "未知参数: $1"; usage; exit 2 ;;
  esac
done

OS="$(uname -s 2>/dev/null || echo unknown)"
step title "DeepSeek Harness 一键安装 / 启动"
step info "平台: $OS"

SCRIPT_DIR=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

fetch_config() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 "$url" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" || true
  else
    return 0
  fi
}

json_get() {
  # json_get <json> <key> — minimal extractor without jq dependency
  local json="$1" key="$2"
  if command -v node >/dev/null 2>&1; then
    node -e 'const j=JSON.parse(process.argv[1]); const k=process.argv[2]; const v=j[k]; if(v==null) process.exit(2); if(Array.isArray(v)) console.log(v.join("\n")); else console.log(String(v));' "$json" "$key" 2>/dev/null || true
    return 0
  fi
  # naive regex fallback for simple string fields
  printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

CFG_JSON=''
if [ -n "$CONFIG_URL" ]; then
  step info "拉取配置: $CONFIG_URL"
  CFG_JSON="$(fetch_config "$CONFIG_URL" || true)"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../config/defaults.json" ]; then
  CFG_JSON="$(cat "$SCRIPT_DIR/../config/defaults.json")"
  step info "读取本地 config/defaults.json"
fi

if [ -n "$CFG_JSON" ]; then
  v="$(json_get "$CFG_JSON" apiKey || true)"
  [ -n "${v:-}" ] && [ -z "$API_KEY" ] && API_KEY="$v"
  v="$(json_get "$CFG_JSON" baseURL || true)"
  [ -n "${v:-}" ] && [ -z "$BASE_URL" ] && BASE_URL="$v"
  v="$(json_get "$CFG_JSON" cliPackage || true)"
  [ -n "${v:-}" ] && PACKAGE="$v"
fi

API_KEY="${API_KEY:-$DEFAULT_API_KEY}"
BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"

version_ok() {
  local raw="${1#v}"
  local major minor patch
  IFS=. read -r major minor patch <<<"$raw"
  major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
  if [ "$major" -eq 23 ]; then
    return 1
  fi
  if [ "$major" -ge 24 ]; then
    return 0
  fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; then
    return 0
  fi
  return 1
}

install_node() {
  step info 'Trying to install Node.js…'
  if [ "$OS" = 'Darwin' ] && command -v brew >/dev/null 2>&1; then
    brew install node@24 || brew install node
    if [ -d /opt/homebrew/opt/node@24/bin ]; then
      export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    elif [ -d /usr/local/opt/node@24/bin ]; then
      export PATH="/usr/local/opt/node@24/bin:$PATH"
    fi
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    step warn 'Debian/Ubuntu: NodeSource 24.x (may need sudo)'
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
      sudo apt-get install -y nodejs
      return 0
    fi
  fi

  if command -v dnf >/dev/null 2>&1; then
    step warn 'Fedora: dnf install nodejs (may need sudo)'
    sudo dnf install -y nodejs || true
    return 0
  fi

  return 1
}

set_yaml_key() {
  local path="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ] && grep -qE "^[[:space:]]*${key}[[:space:]]*:" "$path"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
        print k ": " v; done=1; next
      }
      {print}
      END{if(!done) print k ": " v}
    ' "$path" >"$tmp"
    mv "$tmp" "$path"
  else
    printf '%s: %s\n' "$key" "$value" >>"$path"
  fi
  chmod 600 "$path" 2>/dev/null || true
}

set_dotenv_key() {
  local path="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ] && grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$path"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
        print k "=" v; done=1; next
      }
      {print}
      END{if(!done) print k "=" v}
    ' "$path" >"$tmp"
    mv "$tmp" "$path"
  else
    printf '%s=%s\n' "$key" "$value" >>"$path"
  fi
  chmod 600 "$path" 2>/dev/null || true
}

write_credentials() {
  local home_dir cred_path env_path
  home_dir="${DSH_HOME:-$HOME/.dsh}"
  mkdir -p "$home_dir"
  cred_path="$home_dir/.credentials.yaml"
  env_path="$home_dir/.env"
  set_yaml_key "$cred_path" 'DEEPSEEK_API_KEY' "$API_KEY"
  set_dotenv_key "$env_path" 'DEEPSEEK_BASE_URL' "$BASE_URL"
  set_dotenv_key "$env_path" 'DEEPSEEK_API_KEY' "$API_KEY"
  step ok "credentials: $cred_path"
  step ok "env: $env_path"
}

# Returns fix id via stdout: none | manual-key | install-node | write-credentials | launch
diagnose() {
  local node_ver=''
  local home_dir cred_path env_path

  if printf '%s' "$API_KEY" | grep -Eq 'REPLACE_WITH_YOUR_KEY|sk-xxx|changeme|^$'; then
    printf '%s\n' 'manual-key'
    return 0
  fi
  if [ -z "${BASE_URL:-}" ]; then
    printf '%s\n' 'manual-baseurl'
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    node_ver="$(node -v 2>/dev/null || true)"
  fi
  if [ -z "$node_ver" ] || ! version_ok "$node_ver"; then
    printf '%s\n' 'install-node'
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    printf '%s\n' 'install-node'
    return 0
  fi

  if [ "$CHECK_ONLY" -eq 0 ]; then
    home_dir="${DSH_HOME:-$HOME/.dsh}"
    cred_path="$home_dir/.credentials.yaml"
    env_path="$home_dir/.env"
    if [ ! -f "$cred_path" ] || ! grep -qE '^[[:space:]]*DEEPSEEK_API_KEY[[:space:]]*:' "$cred_path"; then
      printf '%s\n' 'write-credentials'
      return 0
    fi
    if [ ! -f "$env_path" ] || ! grep -qE '^[[:space:]]*DEEPSEEK_BASE_URL[[:space:]]*=' "$env_path"; then
      printf '%s\n' 'write-credentials'
      return 0
    fi
  fi

  if [ "$CHECK_ONLY" -eq 0 ] && [ "$NO_LAUNCH" -eq 0 ]; then
    printf '%s\n' 'launch'
    return 0
  fi

  printf '%s\n' 'none'
}

observe() {
  local node_ver='missing'
  step title 'Agent observe: environment facts'
  step info "platform: $OS"
  if command -v node >/dev/null 2>&1; then
    node_ver="$(node -v 2>/dev/null || echo missing)"
  fi
  step info "node: $node_ver"
  if command -v npm >/dev/null 2>&1; then
    step info "npm: $(npm -v 2>/dev/null || echo missing)"
  else
    step info 'npm: missing'
  fi
  step info "npx: $(command -v npx >/dev/null 2>&1 && echo ok || echo missing)"
  step info "key: $(mask_secret "$API_KEY") base: $BASE_URL"
  step info "package: $PACKAGE ${LAUNCH_ARGS[*]}"
}

act() {
  local fix="$1"
  case "$fix" in
    manual-key)
      step err 'API key missing/placeholder. Set defaults.json or --api-key / DSH_ONBOARD_API_KEY'
      return 2
      ;;
    manual-baseurl)
      step err 'Base URL missing. Set defaults.json or --base-url / DSH_ONBOARD_BASE_URL'
      return 2
      ;;
    install-node)
      if [ "$SKIP_NODE_INSTALL" -eq 1 ]; then
        step err 'Node install skipped by flag'
        return 2
      fi
      if install_node; then
        return 0
      fi
      step err 'Auto-install failed. Install Node 22.19+ or 24+ from https://nodejs.org/'
      return 1
      ;;
    write-credentials)
      write_credentials
      return 0
      ;;
    launch)
      step title "Launch: npx -y $PACKAGE ${LAUNCH_ARGS[*]}"
      step info 'Default Web UI: http://127.0.0.1:3080'
      export DEEPSEEK_API_KEY="$API_KEY"
      export DEEPSEEK_BASE_URL="$BASE_URL"
      exec npx -y "$PACKAGE" "${LAUNCH_ARGS[@]}"
      ;;
    *)
      step err "Unknown fix: $fix"
      return 1
      ;;
  esac
}

step title 'DeepSeek Harness environment agent'
step info 'Loop: observe -> diagnose -> act -> verify (local playbook agent, not an LLM)'
step info "mode: check_only=$CHECK_ONLY no_launch=$NO_LAUNCH max_rounds=$MAX_ROUNDS"

TRIED_INSTALL=0
ROUND=1
while [ "$ROUND" -le "$MAX_ROUNDS" ]; do
  step title "Agent round $ROUND/$MAX_ROUNDS"
  observe
  FIX="$(diagnose)"
  step title "Agent diagnose: fix=$FIX"

  if [ "$FIX" = 'none' ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      step ok 'Agent done: environment checks passed (check-only)'
      exit 0
    fi
    if [ "$NO_LAUNCH" -eq 1 ]; then
      step ok 'Agent done: credentials configured (--no-launch)'
      step info "Manual start: npx -y $PACKAGE ${LAUNCH_ARGS[*]}"
      exit 0
    fi
    step ok 'Agent done: no outstanding issues'
    exit 0
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    step warn 'Check-only: issues remain; no automatic fixes applied'
    exit 1
  fi

  if [ "$FIX" = 'install-node' ] && [ "$TRIED_INSTALL" -eq 1 ]; then
    step err "Fix '$FIX' already attempted and still needed — stopping"
    step warn 'Install Node.js 22.19+ or 24+ manually, reopen terminal, rerun command'
    exit 1
  fi

  step title "Agent act: $FIX"
  set +e
  act "$FIX"
  rc=$?
  set -e
  if [ "$FIX" = 'install-node' ]; then
    TRIED_INSTALL=1
  fi
  if [ "$rc" -eq 2 ]; then
    step err 'Agent blocked (needs manual input)'
    exit 2
  fi
  if [ "$rc" -ne 0 ]; then
    step warn "Fix failed rc=$rc; will re-observe if rounds remain"
  else
    step ok 'Change applied; re-observing...'
  fi
  ROUND=$((ROUND + 1))
done

step err 'Agent stopped: max rounds reached with unresolved issues'
exit 1
