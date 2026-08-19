#!/usr/bin/env bash
# DeepSeek Harness (dsh) 一键环境检测、依赖安装、凭据写入与启动。
#
# 用法（推荐，从站点复制）:
#   curl -fsSL https://<你的站点>/scripts/bootstrap.sh | bash
#
# 本地调试:
#   ./bootstrap.sh
#   ./bootstrap.sh --check-only
#   ./bootstrap.sh --no-launch
#   ./bootstrap.sh --api-key 'sk-xxx' --base-url 'https://api.example/v1'
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

if printf '%s' "$API_KEY" | grep -Eq 'REPLACE_WITH_YOUR_KEY|sk-xxx|changeme'; then
  step err '检测到占位 API Key。请先在 config/defaults.json 或脚本顶部写入真实密钥。'
  step warn "也可: ./bootstrap.sh --api-key 'sk-你的密钥' --base-url 'https://你的端点'"
  exit 2
fi

step info "API Key: $(mask_secret "$API_KEY")"
step info "Base URL: $BASE_URL"
step info "Package:  $PACKAGE ${LAUNCH_ARGS[*]}"

version_ok() {
  # $1 = v22.19.0 or 22.19.0
  local raw="${1#v}"
  local major minor patch
  IFS=. read -r major minor patch <<<"$raw"
  major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
  if [ "$major" -gt 22 ]; then
    # engines: ^22.19.0 || >=24.0.0  → Node 23 is outside the range
    if [ "$major" -eq 23 ]; then
      return 1
    fi
    return 0
  fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; then
    return 0
  fi
  return 1
}

install_node() {
  step info '尝试自动安装 Node.js…'
  if [ "$OS" = 'Darwin' ] && command -v brew >/dev/null 2>&1; then
    brew install node@24 || brew install node
    # brew keg-only paths
    if [ -d /opt/homebrew/opt/node@24/bin ]; then
      export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    elif [ -d /usr/local/opt/node@24/bin ]; then
      export PATH="/usr/local/opt/node@24/bin:$PATH"
    fi
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    step warn 'Debian/Ubuntu: 尝试 NodeSource 24.x（需要 sudo）'
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
      sudo apt-get install -y nodejs
      return 0
    fi
  fi

  if command -v dnf >/dev/null 2>&1; then
    step warn 'Fedora: 尝试 dnf 安装 nodejs（需要 sudo）'
    sudo dnf install -y nodejs || true
    return 0
  fi

  return 1
}

step title '检查 Node.js…'
NODE_VER=''
if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node -v 2>/dev/null || true)"
fi

if [ -n "$NODE_VER" ] && version_ok "$NODE_VER"; then
  step ok "Node.js $NODE_VER 满足要求 (^22.19 || >=24)"
elif [ -n "$NODE_VER" ]; then
  step warn "Node.js $NODE_VER 版本过低，需要 ^22.19.0 或 >=24"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 1
  fi
  if [ "$SKIP_NODE_INSTALL" -eq 1 ]; then
    step err '已跳过自动安装'
    exit 1
  fi
  if ! install_node; then
    step err '自动安装失败。请安装 Node.js 22.19+ 或 24+: https://nodejs.org/'
    exit 1
  fi
  NODE_VER="$(node -v 2>/dev/null || true)"
  if [ -z "$NODE_VER" ] || ! version_ok "$NODE_VER"; then
    step err '安装后仍未检测到合格 Node。请重开终端后重试。'
    exit 1
  fi
  step ok "Node.js $NODE_VER 已就绪"
else
  step warn '未检测到 Node.js'
  if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 1
  fi
  if [ "$SKIP_NODE_INSTALL" -eq 1 ]; then
    step err '已跳过自动安装'
    exit 1
  fi
  if ! install_node; then
    step err '自动安装失败。请安装 Node.js 22.19+ 或 24+: https://nodejs.org/'
    exit 1
  fi
  NODE_VER="$(node -v 2>/dev/null || true)"
  if [ -z "$NODE_VER" ] || ! version_ok "$NODE_VER"; then
    step err '安装后仍未检测到合格 Node。请重开终端后重试。'
    exit 1
  fi
  step ok "Node.js $NODE_VER 已就绪"
fi

if ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  step err '未找到 npm/npx（应随 Node.js 安装）。请修复 PATH 后重试。'
  exit 1
fi
step ok "npm $(npm -v) / npx 可用"

if [ "$CHECK_ONLY" -eq 1 ]; then
  step ok '环境检查通过（check-only，未写凭据、未启动）'
  exit 0
fi

step title '写入默认凭据与端点…'
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
mkdir -p "$DSH_HOME_DIR"
CRED_PATH="$DSH_HOME_DIR/.credentials.yaml"
ENV_PATH="$DSH_HOME_DIR/.env"

set_yaml_key() {
  local path="$1" key="$2" value="$3"
  if [ -f "$path" ] && grep -qE "^[[:space:]]*${key}[[:space:]]*:" "$path"; then
    # portable-ish in-place replace
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

set_yaml_key "$CRED_PATH" 'DEEPSEEK_API_KEY' "$API_KEY"
set_dotenv_key "$ENV_PATH" 'DEEPSEEK_BASE_URL' "$BASE_URL"
set_dotenv_key "$ENV_PATH" 'DEEPSEEK_API_KEY' "$API_KEY"

step ok "凭据: $CRED_PATH"
step ok "环境: $ENV_PATH (DEEPSEEK_BASE_URL)"

if [ "$NO_LAUNCH" -eq 1 ]; then
  step ok '已配置完成（--no-launch，不启动）'
  step info "手动启动: npx -y $PACKAGE ${LAUNCH_ARGS[*]}"
  exit 0
fi

step title "启动: npx -y $PACKAGE ${LAUNCH_ARGS[*]}"
step info '默认 Web UI: http://127.0.0.1:3080 （以终端输出为准）'
export DEEPSEEK_API_KEY="$API_KEY"
export DEEPSEEK_BASE_URL="$BASE_URL"
exec npx -y "$PACKAGE" "${LAUNCH_ARGS[@]}"
