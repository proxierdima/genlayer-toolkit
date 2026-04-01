#!/usr/bin/env bash
set -Eeuo pipefail

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  read -r -p "Enter full install path (DIR): " DIR
fi
[[ -n "$DIR" ]] || { echo "ERROR: DIR is empty" >&2; exit 1; }

mkdir -p "$DIR"/{docs,examples}

cat > "$DIR/toolkit.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENLAYER_WORKSPACE="${GENLAYER_WORKSPACE:-$HOME/genlayer}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

ui_header() {
  gum style \
    --border rounded \
    --padding "1 2" \
    --margin "1 0" \
    --foreground 212 \
    --border-foreground 212 \
    "GenLayer Toolkit" \
    "Install, configure, and manage full node."
}

show_workspace_info() {
  gum style --border rounded --padding "1 2" --margin "1 0" "$(printf '%s\n' \
    "Workspace: $GENLAYER_WORKSPACE" \
    "Toolkit:   $ROOT_DIR")"
}

pause_enter() {
  printf '\n'
  read -r -p "Press Enter to continue..."
}

run_and_pause() {
  local rc=0
  set +e
  "$@"
  rc=$?
  set -e
  echo
  echo "Command finished with code $rc."
  pause_enter
  return 0
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$GENLAYER_WORKSPACE" && docker compose "$@")
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    (cd "$GENLAYER_WORKSPACE" && docker-compose "$@")
    return
  fi
  echo "ERROR: docker compose not found" >&2
  return 1
}

compose_services() {
  compose_cmd config --services 2>/dev/null || true
}

pick_node_service() {
  local services
  services="$(compose_services)"
  if printf '%s\n' "$services" | grep -qx 'genlayer-node'; then
    echo 'genlayer-node'
    return 0
  fi
  printf '%s\n' "$services" | grep -E '^genlayer' | grep -vEi 'web.?driver|alloy' | head -n1
}

read_env_value() {
  local key="$1"
  [[ -f "$GENLAYER_WORKSPACE/.env" ]] || return 0
  grep -E "^${key}=" "$GENLAYER_WORKSPACE/.env" | tail -n1 | cut -d= -f2- || true
}

read_cfg_value() {
  local path="$1"
  local cfg="$GENLAYER_WORKSPACE/configs/node/config.yaml"
  [[ -f "$cfg" ]] || return 0
  CONFIG_FILE="$cfg" CFG_PATH="$path" python3 - <<'PY'
from pathlib import Path
import os, re
cfg = Path(os.environ["CONFIG_FILE"]).read_text().splitlines(True)
target = tuple(os.environ["CFG_PATH"].split("."))
stack = []
line_re = re.compile(r'^(\s*)([A-Za-z0-9_]+):(.*)$')
for line in cfg:
    m = line_re.match(line.rstrip("\n"))
    if not m:
        continue
    indent, key, rest = m.groups()
    indent_len = len(indent)
    while stack and indent_len <= stack[-1][0]:
        stack.pop()
    path = tuple(k for _, k in stack) + (key,)
    if path == target:
        value = rest.strip().split("#", 1)[0].rstrip().strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        print(value)
        break
    if rest.strip() == "":
        stack.append((indent_len, key))
PY
}

ask_input() { gum input --prompt "> " --placeholder "$1" --value "${2:-}"; }
is_http_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
is_ws_url() { [[ "$1" =~ ^wss?://[^[:space:]]+$ ]]; }
is_eth_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_env_name() { [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]]; }

ask_http_url() {
  local prompt="$1" default_value="${2:-}" out
  while true; do
    out="$(ask_input "$prompt" "$default_value")" || return 1
    is_http_url "$out" && { printf '%s' "$out"; return 0; }
    gum log --level error "Expected http:// or https://"
  done
}

ask_ws_url() {
  local prompt="$1" default_value="${2:-}" out
  while true; do
    out="$(ask_input "$prompt" "$default_value")" || return 1
    is_ws_url "$out" && { printf '%s' "$out"; return 0; }
    gum log --level error "Expected ws:// or wss://"
  done
}

ask_eth_addr() {
  local prompt="$1" default_value="${2:-}" out
  while true; do
    out="$(ask_input "$prompt" "$default_value")" || return 1
    is_eth_addr "$out" && { printf '%s' "$out"; return 0; }
    gum log --level error "Expected 0x + 40 hex chars"
  done
}

toolkit_install_base_packages() {
  local SUDO=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    SUDO="sudo"
  fi

  need_cmd apt-get
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl wget tar xz-utils jq python3 rsync gpg lsb-release

  if ! command -v gum >/dev/null 2>&1; then
    $SUDO mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null
    $SUDO apt-get update
    $SUDO apt-get install -y gum
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "WARN: docker not found. Install Docker first."
  fi
}

toolkit_download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

toolkit_resolve_latest_node_version() {
  local latest
  latest="$(curl -fsS "https://storage.googleapis.com/storage/v1/b/gh-af/o?prefix=genlayer-node/bin/amd64" \
    | grep -o '"name": *"[^"]*"' \
    | sed -n 's/.*\/\(v[^/]*\)\/.*/\1/p' \
    | sort -Vr \
    | head -1 || true)"
  if [[ -n "$latest" ]]; then
    printf '%s' "$latest"
  else
    printf '%s' 'v0.5.7'
  fi
}

toolkit_seed_example_files() {
  mkdir -p "$GENLAYER_WORKSPACE/configs/node" "$GENLAYER_WORKSPACE/data"
  [[ -f "$GENLAYER_WORKSPACE/.env" ]] || cp "$ROOT_DIR/examples/env.example" "$GENLAYER_WORKSPACE/.env"
  [[ -f "$GENLAYER_WORKSPACE/configs/node/config.yaml" ]] || cp "$ROOT_DIR/examples/config.yaml" "$GENLAYER_WORKSPACE/configs/node/config.yaml"
  if [[ ! -f "$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml" ]]; then
    if [[ -f "$GENLAYER_WORKSPACE/third_party/genvm/config/genvm-module-web.yaml" ]]; then
      cp "$GENLAYER_WORKSPACE/third_party/genvm/config/genvm-module-web.yaml" "$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml"
      sed -i 's|^webdriver_host:.*$|webdriver_host: http://webdriver-container:4444|' "$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml" || true
    else
      cp "$ROOT_DIR/examples/genvm-module-web-docker.yaml" "$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml"
    fi
  fi
}

toolkit_bootstrap_workspace_sh() {
  local NODE_VERSION="${NODE_VERSION:-latest}"
  local GENVM_EXECUTOR_VERSION="${GENVM_EXECUTOR_VERSION:-v0.2.16}"
  local GENVM_LINUX_AMD64_VERSION="${GENVM_LINUX_AMD64_VERSION:-${GENVM_EXECUTOR_VERSION}}"
  local GENVM_UNIVERSAL_VERSION="${GENVM_UNIVERSAL_VERSION:-${GENVM_EXECUTOR_VERSION}}"
  local FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-0}"
  local tmpdir=""

  toolkit_install_base_packages

  if [[ "$NODE_VERSION" == "latest" || "$NODE_VERSION" == "auto" || -z "$NODE_VERSION" ]]; then
    NODE_VERSION="$(toolkit_resolve_latest_node_version)"
  fi

  local NODE_URL="https://storage.googleapis.com/gh-af/genlayer-node/bin/amd64/${NODE_VERSION}/genlayer-node-linux-amd64-${NODE_VERSION}.tar.gz"
  local GENVM_EXECUTOR_URL="https://github.com/genlayerlabs/genvm/releases/download/${GENVM_EXECUTOR_VERSION}/genvm-linux-amd64-executor.tar.xz"
  local GENVM_LINUX_AMD64_URL="https://github.com/genlayerlabs/genvm/releases/download/${GENVM_LINUX_AMD64_VERSION}/genvm-linux-amd64.tar.xz"
  local GENVM_UNIVERSAL_URL="https://github.com/genlayerlabs/genvm/releases/download/${GENVM_UNIVERSAL_VERSION}/genvm-universal.tar.xz"

  cleanup_tmpdir() {
    if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
      rm -rf "$tmpdir"
    fi
  }
  trap cleanup_tmpdir RETURN

  if [[ -x "$GENLAYER_WORKSPACE/bin/genlayernode" && "$FORCE_BOOTSTRAP" != "1" ]]; then
    echo "Workspace already exists: $GENLAYER_WORKSPACE"
    toolkit_seed_example_files
    return 0
  fi

  tmpdir="$(mktemp -d)"

  local node_archive="$tmpdir/genlayer-node.tar.gz"
  local executor_archive="$tmpdir/genvm-executor.tar.xz"
  local linux_amd64_archive="$tmpdir/genvm-linux-amd64.tar.xz"
  local universal_archive="$tmpdir/genvm-universal.tar.xz"

  echo "Downloading node package: $NODE_VERSION"
  toolkit_download_file "$NODE_URL" "$node_archive"
  echo "Downloading genvm executor package: $GENVM_EXECUTOR_VERSION"
  toolkit_download_file "$GENVM_EXECUTOR_URL" "$executor_archive"
  echo "Downloading genvm linux-amd64 package: $GENVM_LINUX_AMD64_VERSION"
  toolkit_download_file "$GENVM_LINUX_AMD64_URL" "$linux_amd64_archive"
  echo "Downloading genvm universal package: $GENVM_UNIVERSAL_VERSION"
  toolkit_download_file "$GENVM_UNIVERSAL_URL" "$universal_archive"

  mkdir -p "$tmpdir/node"
  tar -xzf "$node_archive" -C "$tmpdir/node"
  local root
  root="$(find "$tmpdir/node" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$root" && -d "$root" ]] || { echo "ERROR: failed to detect node archive root" >&2; return 1; }

  if [[ -d "$GENLAYER_WORKSPACE" && "$FORCE_BOOTSTRAP" == "1" ]]; then
    mv "$GENLAYER_WORKSPACE" "${GENLAYER_WORKSPACE}.backup.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ ! -d "$GENLAYER_WORKSPACE" || "$FORCE_BOOTSTRAP" == "1" ]]; then
    mkdir -p "$(dirname "$GENLAYER_WORKSPACE")"
    mv "$root" "$GENLAYER_WORKSPACE"
  fi

  local genvm_dir="$GENLAYER_WORKSPACE/third_party/genvm"
  local keep_tmp="$tmpdir/setup.py.keep"
  mkdir -p "$genvm_dir/bin"
  [[ -f "$genvm_dir/bin/setup.py" ]] && cp "$genvm_dir/bin/setup.py" "$keep_tmp"
  find "$genvm_dir" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
  find "$genvm_dir/bin" -mindepth 1 -maxdepth 1 ! -name setup.py -exec rm -rf {} + || true
  [[ -f "$keep_tmp" ]] && cp "$keep_tmp" "$genvm_dir/bin/setup.py"

  local work
  for item in executor linux-amd64 universal; do
    work="$tmpdir/$item"
    rm -rf "$work"
    mkdir -p "$work"
    case "$item" in
      executor) tar -xJf "$executor_archive" -C "$work" ;;
      linux-amd64) tar -xJf "$linux_amd64_archive" -C "$work" ;;
      universal) tar -xJf "$universal_archive" -C "$work" ;;
    esac
    rsync -a --exclude 'bin/setup.py' "$work/" "$genvm_dir/"
  done

  toolkit_seed_example_files
  if [[ -f "$GENLAYER_WORKSPACE/third_party/genvm/bin/setup.py" ]]; then
    (cd "$GENLAYER_WORKSPACE" && python3 ./third_party/genvm/bin/setup.py) || echo "WARN: genvm setup.py failed"
  fi

  echo "Workspace ready: $GENLAYER_WORKSPACE"
}

toolkit_write_env_values() {
  local env_file="$GENLAYER_WORKSPACE/.env"
  mkdir -p "$(dirname "$env_file")"
  [[ -f "$env_file" ]] || cp "$ROOT_DIR/examples/env.example" "$env_file"

  ENV_FILE="$env_file" \
  WORKSPACE_DIR="$GENLAYER_WORKSPACE" \
  WEBDRIVER_PORT_VALUE="4444" \
  NODE_VERSION_VALUE="latest" \
  NODE_RPC_PORT_VALUE="9151" \
  NODE_OPS_PORT_VALUE="9153" \
  LLM_VAR_NAME_VALUE="$1" \
  LLM_VAR_SECRET_VALUE="$2" \
  python3 - <<'PY'
from pathlib import Path
import os, re
p = Path(os.environ["ENV_FILE"])
text = p.read_text() if p.exists() else ""
updates = {
    "WEBDRIVER_PORT": os.environ["WEBDRIVER_PORT_VALUE"],
    "NODE_VERSION": os.environ["NODE_VERSION_VALUE"],
    "NODE_CONFIG_PATH": str(Path(os.environ["WORKSPACE_DIR"]) / "configs/node/config.yaml"),
    "NODE_DATA_PATH": str(Path(os.environ["WORKSPACE_DIR"]) / "data"),
    "NODE_RPC_PORT": os.environ["NODE_RPC_PORT_VALUE"],
    "NODE_OPS_PORT": os.environ["NODE_OPS_PORT_VALUE"],
    "GENLAYERNODE_LOGGING_LEVEL": "INFO",
    "LLM_PROVIDER_VAR": os.environ["LLM_VAR_NAME_VALUE"],
    os.environ["LLM_VAR_NAME_VALUE"]: os.environ.get("LLM_VAR_SECRET_VALUE", ""),
    "NODE_MODE": "full",
    "VALIDATOR_WALLET_ADDRESS": "",
    "OPERATOR_ADDRESS": "",
}
for key, value in updates.items():
    line = f"{key}={value}"
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if pattern.search(text):
        text = pattern.sub(line, text, count=1)
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text += line + "\n"
p.write_text(text)
PY
}

toolkit_write_config_values() {
  local rpc_url="$1"
  local ws_url="$2"
  local consensus_address="$3"
  local genesis="$4"
  local node_config_file="$GENLAYER_WORKSPACE/configs/node/config.yaml"
  local genvm_web_file="$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml"

  mkdir -p "$GENLAYER_WORKSPACE/configs/node" "$GENLAYER_WORKSPACE/data"
  [[ -f "$node_config_file" ]] || cp "$ROOT_DIR/examples/config.yaml" "$node_config_file"
  [[ -f "$genvm_web_file" ]] || cp "$ROOT_DIR/examples/genvm-module-web-docker.yaml" "$genvm_web_file"

  CONFIG_FILE="$node_config_file" \
  RPC_URL="$rpc_url" \
  WS_URL="$ws_url" \
  CONSENSUS_ADDRESS="$consensus_address" \
  GENESIS="$genesis" \
  python3 - <<'PY'
import os, re, sys, tempfile
from pathlib import Path
config_path = Path(os.environ["CONFIG_FILE"])
lines = config_path.read_text(encoding="utf-8").splitlines(True)

def yaml_quote(value: str) -> str:
    if value.replace('.', '', 1).isdigit() or value in ("true", "false", "null"):
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

wanted = {
    ("rollup", "genlayerchainrpcurl"): yaml_quote(os.environ["RPC_URL"]),
    ("rollup", "genlayerchainwebsocketurl"): yaml_quote(os.environ["WS_URL"]),
    ("consensus", "consensusaddress"): yaml_quote(os.environ["CONSENSUS_ADDRESS"]),
    ("consensus", "genesis"): os.environ["GENESIS"],
    ("logging", "level"): yaml_quote("INFO"),
    ("node", "mode"): yaml_quote("full"),
    ("node", "validatorWalletAddress"): yaml_quote(""),
    ("node", "operatorAddress"): yaml_quote(""),
    ("node", "admin", "port"): "9155",
    ("node", "rpc", "port"): "9151",
    ("node", "ops", "port"): "9153",
    ("node", "ops", "endpoints", "balance"): "false",
}
line_re = re.compile(r'^(\s*)([A-Za-z0-9_]+):(.*?)(\r?\n?)$')
stack = []
seen = set()
for i, line in enumerate(lines):
    m = line_re.match(line)
    if not m:
        continue
    indent, key, rest, nl = m.groups()
    indent_len = len(indent)
    while stack and indent_len <= stack[-1][0]:
        stack.pop()
    current_path = tuple(k for _, k in stack) + (key,)
    comment = ""
    value_part = rest
    if "#" in rest:
        hash_pos = rest.index("#")
        value_part = rest[:hash_pos]
        comment = rest[hash_pos:].rstrip("\r\n")
    if current_path in wanted:
        new_value = wanted[current_path]
        new_line = f"{indent}{key}: {new_value}"
        if comment:
            new_line += f" {comment}"
        new_line += nl or "\n"
        lines[i] = new_line
        seen.add(current_path)
    if value_part.strip() == "":
        stack.append((indent_len, key))
missing = [path for path in wanted if path not in seen]
if missing:
    print("ERROR: missing config keys:", ", ".join(".".join(x) for x in missing), file=sys.stderr)
    sys.exit(1)
with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', delete=False, dir=config_path.parent) as tmp:
    tmp.write(''.join(lines))
os.replace(tmp.name, config_path)
PY

  GENVM_WEB_FILE="$genvm_web_file" python3 - <<'PY'
from pathlib import Path
import os, re
p = Path(os.environ["GENVM_WEB_FILE"])
text = p.read_text() if p.exists() else ""
value = "webdriver_host: http://webdriver-container:4444"
pattern = re.compile(r'(?m)^([ \t]*webdriver_host:[ \t]*).*$')
if pattern.search(text):
    text = pattern.sub(value, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += value + "\n"
p.write_text(text)
PY
}

toolkit_choose_network_defaults() {
  local current_consensus="$1"
  local current_genesis="$2"
  local current_rpc="$3"
  local current_ws="$4"

  local default_choice="Custom"
  case "$current_consensus" in
    0xe66B434bc83805f380509642429eC8e43AE9874a) default_choice="Asimov" ;;
    0x8aCE036C8C3C5D603dB546b031302FCf149648E8) default_choice="Bradbury" ;;
  esac

  local choice
  choice="$(gum choose --header "Select network" "$default_choice" "Asimov" "Bradbury" "Custom" | awk '!seen[$0]++')" || return 1

  case "$choice" in
    Asimov)
      printf '%s\n' "Asimov|https://zksync-os-testnet-genlayer.zksync.dev|wss://zksync-os-testnet-genlayer.zksync.dev/ws|0xe66B434bc83805f380509642429eC8e43AE9874a|17326"
      ;;
    Bradbury)
      printf '%s\n' "Bradbury|https://zksync-os-testnet-genlayer.zksync.dev|wss://zksync-os-testnet-genlayer.zksync.dev/ws|0x8aCE036C8C3C5D603dB546b031302FCf149648E8|501711"
      ;;
    Custom)
      printf '%s\n' "Custom|${current_rpc:-https://zksync-os-testnet-genlayer.zksync.dev}|${current_ws:-wss://zksync-os-testnet-genlayer.zksync.dev/ws}|${current_consensus:-0xe66B434bc83805f380509642429eC8e43AE9874a}|${current_genesis:-17326}"
      ;;
  esac
}

toolkit_choose_llm_provider() {
  local current_llm_name="$1"
  local options=()
  [[ -n "$current_llm_name" ]] && options+=("$current_llm_name")
  options+=("OPENROUTERKEY" "HEURISTKEY" "GEMINIKEY" "ANTHROPICKEY" "COMPUT3KEY" "IOINTELLIGENCE_API_KEY" "XAIKEY" "ATOMAKEY" "CHUTES_API_KEY" "MORPHEUS_API_KEY" "Custom")
  gum choose --header "Select LLM provider" "${options[@]}" | awk '!seen[$0]++'
}

toolkit_configure_existing_node_sh() {
  local ENV_FILE="$GENLAYER_WORKSPACE/.env"
  local NODE_CONFIG_FILE="$GENLAYER_WORKSPACE/configs/node/config.yaml"
  local GENVM_WEB_FILE="$GENLAYER_WORKSPACE/genvm-module-web-docker.yaml"

  mkdir -p "$GENLAYER_WORKSPACE/configs/node" "$GENLAYER_WORKSPACE/data"
  [[ -f "$ENV_FILE" ]] || cp "$ROOT_DIR/examples/env.example" "$ENV_FILE"
  [[ -f "$NODE_CONFIG_FILE" ]] || cp "$ROOT_DIR/examples/config.yaml" "$NODE_CONFIG_FILE"
  [[ -f "$GENVM_WEB_FILE" ]] || cp "$ROOT_DIR/examples/genvm-module-web-docker.yaml" "$GENVM_WEB_FILE"

  ui_header

  local current_rpc current_ws current_consensus current_genesis current_llm_name current_llm_value
  current_rpc="$(read_cfg_value "rollup.genlayerchainrpcurl")"
  current_ws="$(read_cfg_value "rollup.genlayerchainwebsocketurl")"
  current_consensus="$(read_cfg_value "consensus.consensusaddress")"
  current_genesis="$(read_cfg_value "consensus.genesis")"
  current_llm_name="$(read_env_value LLM_PROVIDER_VAR)"
  current_llm_name="${current_llm_name:-OPENROUTERKEY}"
  current_llm_value="$(read_env_value "$current_llm_name")"

  local network_line network_name rpc_default ws_default consensus_default genesis_default
  network_line="$(toolkit_choose_network_defaults "$current_consensus" "$current_genesis" "$current_rpc" "$current_ws")" || return 1
  IFS='|' read -r network_name rpc_default ws_default consensus_default genesis_default <<< "$network_line"

  local rpc_url ws_url consensus_address genesis llm_name llm_value
  rpc_url="$rpc_default"
  ws_url="$ws_default"
  consensus_address="$consensus_default"
  genesis="$genesis_default"
  llm_name="$current_llm_name"
  llm_value="$current_llm_value"

  if [[ "$network_name" == "Custom" ]]; then
    rpc_url="$(ask_http_url "HTTP RPC URL" "$rpc_url")" || return 1
    ws_url="$(ask_ws_url "WSS / WS RPC URL" "$ws_url")" || return 1
    consensus_address="$(ask_eth_addr "Consensus AddressManager address" "$consensus_address")" || return 1
    genesis="$(ask_input "Genesis block number" "$genesis")" || return 1
    is_uint "$genesis" || { echo "ERROR: genesis must be integer" >&2; return 1; }
  else
    echo "Selected network: $network_name"
    echo "RPC: $rpc_url"
    echo "WSS: $ws_url"
    echo "Consensus: $consensus_address"
    echo "Genesis: $genesis"
  fi

  llm_name="$(toolkit_choose_llm_provider "$current_llm_name")" || return 1
  if [[ "$llm_name" == "Custom" ]]; then
    while true; do
      llm_name="$(ask_input "Env variable name" "${current_llm_name:-OPENROUTERKEY}")" || return 1
      llm_name="$(printf '%s' "$llm_name" | tr '[:lower:]' '[:upper:]')"
      is_env_name "$llm_name" && break
      gum log --level error "Expected UPPER_CASE_WITH_UNDERSCORES"
    done
  fi

  if [[ "$llm_name" == "$current_llm_name" && -n "$current_llm_value" ]]; then
    echo "Using existing API key from .env for $llm_name"
    llm_value="$current_llm_value"
  else
    llm_value="$(ask_input "API key for $llm_name" "${current_llm_value:-}")" || return 1
  fi

  cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$NODE_CONFIG_FILE" "$NODE_CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$GENVM_WEB_FILE" "$GENVM_WEB_FILE.bak.$(date +%Y%m%d%H%M%S)"

  toolkit_write_env_values "$llm_name" "$llm_value"
  toolkit_write_config_values "$rpc_url" "$ws_url" "$consensus_address" "$genesis"

  echo "Configuration updated."
}

toolkit_check_config_py() {
  local workspace="$GENLAYER_WORKSPACE"
  local cfg_path="$workspace/configs/node/config.yaml"
  local env_path="$workspace/.env"
  [[ -f "$cfg_path" ]] || { echo "ERROR: missing $cfg_path" >&2; return 2; }
  [[ -f "$env_path" ]] || { echo "ERROR: missing $env_path" >&2; return 2; }

  CFG_PATH="$cfg_path" ENV_PATH="$env_path" python3 - <<'PY'
from pathlib import Path
import os, re, sys
cfg_path = Path(os.environ["CFG_PATH"])
env_path = Path(os.environ["ENV_PATH"])
cfg_text = cfg_path.read_text()
cfg_lines = cfg_text.splitlines(True)
env_lines = env_path.read_text().splitlines()

def yaml_get(lines, target):
    stack = []
    line_re = re.compile(r'^(\s*)([A-Za-z0-9_]+):(.*)$')
    for line in lines:
        m = line_re.match(line.rstrip("\n"))
        if not m:
            continue
        indent, key, rest = m.groups()
        indent_len = len(indent)
        while stack and indent_len <= stack[-1][0]:
            stack.pop()
        path = tuple(k for _, k in stack) + (key,)
        if path == target:
            value = rest.strip()
            if "#" in value:
                value = value.split("#", 1)[0].rstrip()
            value = value.strip()
            if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
                value = value[1:-1]
            return value
        if rest.strip() == "":
            stack.append((indent_len, key))
    return None

env = {}
for raw in env_lines:
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k.strip()] = v.strip()

errors, warns = [], []
rpc = yaml_get(cfg_lines, ("rollup", "genlayerchainrpcurl"))
wss = yaml_get(cfg_lines, ("rollup", "genlayerchainwebsocketurl"))
consensus = yaml_get(cfg_lines, ("consensus", "consensusaddress"))
genesis = yaml_get(cfg_lines, ("consensus", "genesis"))
mode = yaml_get(cfg_lines, ("node", "mode"))

def is_eth(v):
    return bool(v) and re.fullmatch(r'0x[0-9a-fA-F]{40}', v) is not None

if not rpc or rpc == "FILLME":
    errors.append("rollup.genlayerchainrpcurl is empty or FILLME")
elif not re.match(r'^https?://', rpc):
    errors.append("rollup.genlayerchainrpcurl must start with http:// or https://")
if not wss or wss == "FILLME":
    errors.append("rollup.genlayerchainwebsocketurl is empty or FILLME")
elif re.match(r'^https?://', wss):
    errors.append("rollup.genlayerchainwebsocketurl is http(s), but must be ws:// or wss://")
elif not re.match(r'^wss?://', wss):
    errors.append("rollup.genlayerchainwebsocketurl must start with ws:// or wss://")
if not is_eth(consensus):
    errors.append("consensus.consensusaddress is invalid")
if not genesis or not genesis.isdigit():
    errors.append("consensus.genesis must be integer")
if mode != "full":
    errors.append("node.mode must be full")
provider_var = env.get("LLM_PROVIDER_VAR", "").strip()
if not provider_var:
    warns.append("LLM_PROVIDER_VAR not found in .env")
else:
    if provider_var not in env:
        errors.append(f"Provider variable {provider_var} is missing in .env")
    elif not env.get(provider_var, "").strip():
        errors.append(f"Provider variable {provider_var} is empty")
if errors:
    print("PRECHECK: FAIL")
    for e in errors:
        print(f"- ERROR: {e}")
else:
    print("PRECHECK: OK")
for w in warns:
    print(f"- WARN: {w}")
sys.exit(1 if errors else 0)
PY
}

toolkit_start_webdriver_sh() {
  echo "Running: docker compose up -d"
  compose_cmd up -d
  compose_cmd ps
}

toolkit_start_node_sh() {
  toolkit_check_config_py || { echo "ERROR: configuration check failed. Fix config before start." >&2; return 1; }
  if [[ -x "$GENLAYER_WORKSPACE/bin/genlayernode" ]]; then
    echo "Running doctor before start..."
    (cd "$GENLAYER_WORKSPACE" && "$GENLAYER_WORKSPACE/bin/genlayernode" doctor) || echo "WARN: doctor returned non-zero"
  fi
  echo "Running: docker compose --profile node up -d"
  compose_cmd --profile node up -d
  compose_cmd ps
}

toolkit_start_full_stack_sh() {
  toolkit_check_config_py || { echo "ERROR: configuration check failed. Fix config before start." >&2; return 1; }
  if [[ -x "$GENLAYER_WORKSPACE/bin/genlayernode" ]]; then
    echo "Running doctor before start..."
    (cd "$GENLAYER_WORKSPACE" && "$GENLAYER_WORKSPACE/bin/genlayernode" doctor) || echo "WARN: doctor returned non-zero"
  fi
  echo "Running: docker compose --profile node --profile monitoring up -d"
  compose_cmd --profile node --profile monitoring up -d
  compose_cmd ps
}

toolkit_stop_stack_sh() {
  echo "Running: docker compose --profile node --profile monitoring down"
  compose_cmd --profile node --profile monitoring down
}

toolkit_restart_node_stack_sh() {
  echo "Running: docker compose --profile node restart"
  compose_cmd --profile node restart
  compose_cmd ps
}

toolkit_logs_follow_sh() {
  echo "Running: docker compose --profile node logs -f"
  echo "Press Ctrl+C to return to menu."
  compose_cmd --profile node logs -f
}

toolkit_install_fullnode_sh() {
  toolkit_bootstrap_workspace_sh || return 1
  toolkit_configure_existing_node_sh || return 1
  toolkit_check_config_py || return 1
  toolkit_start_webdriver_sh || return 1
  toolkit_start_node_sh || return 1
  return 0
}

install_menu() {
  while true; do
    ui_header
    show_workspace_info
    local choice
    choice="$(
      gum choose --header "Install" \
        "Install full node" \
        "Bootstrap workspace only" \
        "Configure existing workspace" \
        "Back"
    )" || return 0

    case "$choice" in
      "Install full node") run_and_pause toolkit_install_fullnode_sh ;;
      "Bootstrap workspace only") run_and_pause toolkit_bootstrap_workspace_sh ;;
      "Configure existing workspace") run_and_pause toolkit_configure_existing_node_sh ;;
      "Back") return 0 ;;
    esac
  done
}

stack_menu() {
  while true; do
    ui_header
    show_workspace_info
    local choice
    choice="$(
      gum choose --header "Stack" \
        "Start node" \
        "Start full stack" \
        "Stop full stack" \
        "Restart node stack" \
        "Follow node logs" \
        "Back"
    )" || return 0

    case "$choice" in
      "Start node") run_and_pause toolkit_start_node_sh ;;
      "Start full stack") run_and_pause toolkit_start_full_stack_sh ;;
      "Stop full stack") run_and_pause toolkit_stop_stack_sh ;;
      "Restart node stack") run_and_pause toolkit_restart_node_stack_sh ;;
      "Follow node logs") toolkit_logs_follow_sh ;;
      "Back") return 0 ;;
    esac
  done
}

main() {
  need_cmd bash
  need_cmd python3
  need_cmd gum
  need_cmd curl
  need_cmd jq

  while true; do
    ui_header
    show_workspace_info
    local choice
    choice="$(
      gum choose --header "Main menu" \
        "Install" \
        "Stack" \
        "Check configuration" \
        "Exit"
    )" || exit 0

    case "$choice" in
      "Install") install_menu ;;
      "Stack") stack_menu ;;
      "Check configuration") run_and_pause toolkit_check_config_py ;;
      "Exit") exit 0 ;;
    esac
  done
}

main "$@"
EOS

cat > "$DIR/examples/env.example" <<'EOS'
WEBDRIVER_PORT=4444
NODE_VERSION=latest
NODE_CONFIG_PATH=./configs/node/config.yaml
NODE_DATA_PATH=./data
NODE_RPC_PORT=9151
NODE_OPS_PORT=9153
GENLAYERNODE_LOGGING_LEVEL=INFO
LLM_PROVIDER_VAR=OPENROUTERKEY
OPENROUTERKEY=
HEURISTKEY=
ANTHROPICKEY=
XAIKEY=
GEMINIKEY=
ATOMAKEY=
CHUTES_API_KEY=
MORPHEUS_API_KEY=
COMPUT3KEY=
IOINTELLIGENCE_API_KEY=
NODE_MODE=full
VALIDATOR_WALLET_ADDRESS=
OPERATOR_ADDRESS=
EOS

cat > "$DIR/examples/config.yaml" <<'EOS'
rollup:
  genlayerchainrpcurl: "FILLME"
  genlayerchainwebsocketurl: "FILLME"
consensus:
  consensusaddress: "0xe66B434bc83805f380509642429eC8e43AE9874a"
  genesis: 17326
datadir: "./data/node"
logging:
  level: "INFO"
  json: false
  file:
    enabled: true
    level: "DEBUG"
    folder: logs
    maxsize: 10
    maxage: 7
    maxbackups: 100
    localtime: false
    compress: true
node:
  mode: "full"
  validatorWalletAddress: ""
  operatorAddress: ""
  admin:
    port: 9155
  rpc:
    port: 9151
    endpoints:
      groups:
        genlayer: true
        genlayer_debug: true
        ethereum: true
        zksync: true
      methods:
        gen_call: true
        gen_getContractSchema: true
        gen_getTransactionStatus: true
        gen_getTransactionReceipt: true
        gen_dbg_ping: true
        eth_blockNumber: true
        eth_getBlockByNumber: true
        eth_getBlockByHash: true
        eth_sendRawTransaction: true
        zks_getTransaction: true
  ops:
    port: 9153
    endpoints:
      metrics: true
      health: true
      balance: false
genvm:
  root_dir: ./third_party/genvm
  start_manager: true
  manager_url: http://127.0.0.1:3999
  permits: 8
metrics:
  interval: "15s"
  collectors:
    node:
      enabled: true
    genvm:
      enabled: true
    webdriver:
      enabled: true
EOS

cat > "$DIR/examples/genvm-module-web-docker.yaml" <<'EOS'
bind_address: 127.0.0.1:3032
webdriver_host: http://webdriver-container:4444
lua_script_path: ${exeDir}/../config/genvm-web-default.lua
vm_count: 6
lua_path: ${exeDir}/../lib/genvm-lua/?.lua
signer_url: "#{signerUrl}"
signer_headers: {}
threads: 4
blocking_threads: 16
log_disable: ""
session_create_request: |
  {
    "capabilities": {
      "alwaysMatch": {
        "browserName": "firefox",
        "moz:firefoxOptions": {
          "args": [
            "--headless"
          ]
        }
      }
    }
  }
extra_tld: []
always_allow_hosts: []
EOS

cat > "$DIR/docs/runbook.md" <<'EOS'
# Runbook

1. Install -> Install full node
2. After configuration the toolkit starts webdriver first, then node
3. Stack -> Follow node logs
EOS

chmod +x "$DIR/toolkit.sh"

echo "Installed to: $DIR"
find "$DIR" -maxdepth 2 -type f | sort
