#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: line ${LINENO}: command failed: ${BASH_COMMAND}" >&2; exit "$rc"' ERR

DEFAULT_HOST="0.0.0.0"
DEFAULT_PORT="8004"
DEFAULT_INSTALL_DIR="/opt/chatterbox"
REPO_URL="https://github.com/devnen/Chatterbox-TTS-Server.git"
SERVICE_NAME="chatterbox.service"
RUN_USER="chatterbox"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
REINSTALL=0
UPDATE_ONLY=0
NO_START=0
PRELOAD_MODELS=0

usage() {
  cat <<USAGE
Usage: sudo bash install_chatterbox_cpu.sh [options]

Options:
  --host HOST              Bind host (default: ${DEFAULT_HOST})
  --port PORT              Bind port (default: ${DEFAULT_PORT})
  --install-dir DIR        Install directory (default: ${DEFAULT_INSTALL_DIR})
  --reinstall              Remove repository/venv and install again
  --update                 Update code and dependencies only
  --no-start               Do not enable/restart the systemd service
  --preload-models         Start service and wait longer so models are downloaded/loaded
  -h, --help               Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?--host requires a value}"; shift 2 ;;
    --port) PORT="${2:?--port requires a value}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:?--install-dir requires a value}"; shift 2 ;;
    --reinstall) REINSTALL=1; shift ;;
    --update) UPDATE_ONLY=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --preload-models) PRELOAD_MODELS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash install_chatterbox_cpu.sh" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid --port: $PORT" >&2
  exit 1
fi
if [[ "$INSTALL_DIR" != /* ]]; then
  echo "--install-dir must be an absolute path" >&2
  exit 1
fi

APP_PARENT="${INSTALL_DIR}/app"
REPO_DIR="${APP_PARENT}/Chatterbox-TTS-Server"
VENV_DIR="${INSTALL_DIR}/venv"
HF_CACHE="${INSTALL_DIR}/hf-cache"
OUTPUT_DIR="${INSTALL_DIR}/output"
VOICES_DIR="${INSTALL_DIR}/voices"
REFERENCE_DIR="${INSTALL_DIR}/reference_audio"
LOG_DIR="/var/log/chatterbox"
CPU_THREADS="20"

log() { printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
run_as_user() { runuser -u "$RUN_USER" -- env HOME="$INSTALL_DIR" PATH="/usr/local/bin:/usr/bin:/bin" "$@"; }

install_system_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential pkg-config ffmpeg libsndfile1 jq python3-venv
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "uv already installed: $(command -v uv)"
    return
  fi
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
  chmod 0755 /usr/local/bin/uv
}

ensure_user_and_dirs() {
  log "Creating user and directories"
  mkdir -p "$INSTALL_DIR" "$APP_PARENT" "$HF_CACHE" "$OUTPUT_DIR" "$VOICES_DIR" "$REFERENCE_DIR" "$LOG_DIR"
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin --user-group "$RUN_USER"
  fi
  chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR" "$LOG_DIR"
}

sync_repo() {
  log "Installing/updating Chatterbox-TTS-Server"
  if (( REINSTALL )); then
    rm -rf "$REPO_DIR" "$VENV_DIR"
  fi
  if [[ -d "$REPO_DIR/.git" ]]; then
    run_as_user git -C "$REPO_DIR" pull --ff-only
  elif [[ -e "$REPO_DIR" ]]; then
    echo "$REPO_DIR exists but is not a git repository. Use --reinstall or remove it." >&2
    exit 1
  else
    run_as_user git clone "$REPO_URL" "$REPO_DIR"
  fi
  chown -R "$RUN_USER:$RUN_USER" "$APP_PARENT"
}

setup_python_and_deps() {
  log "Installing Python 3.10 with uv and project dependencies"
  run_as_user uv python install 3.10
  local venv_python_version=""
  local venv_has_pip=1
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    venv_python_version="$($VENV_DIR/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1 && venv_has_pip=0 || venv_has_pip=1
  fi
  if [[ ! -x "$VENV_DIR/bin/python" || "$venv_python_version" != "3.10" || "$venv_has_pip" -ne 0 ]]; then
    rm -rf "$VENV_DIR"
    run_as_user uv venv --seed --python 3.10 "$VENV_DIR"
  fi
  run_as_user "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  if [[ ! -f "$REPO_DIR/requirements.txt" ]]; then
    echo "requirements.txt not found in $REPO_DIR" >&2
    exit 1
  fi
  run_as_user "$VENV_DIR/bin/python" -m pip install -r "$REPO_DIR/requirements.txt"
  run_as_user "$VENV_DIR/bin/python" -m pip install --no-deps 'git+https://github.com/devnen/chatterbox-v2.git@master' s3tokenizer==0.3.0 onnx==1.16.0
}

patch_config() {
  log "Patching config.yaml"
  if [[ ! -f "$REPO_DIR/config.yaml" ]]; then
    cat > "$REPO_DIR/config.yaml" <<'YAML'
server: {}
model: {}
tts_engine: {}
paths: {}
generation_defaults: {}
audio_output: {}
ui: {}
YAML
  else
    cp -a "$REPO_DIR/config.yaml" "$REPO_DIR/config.yaml.backup.$(date +%Y%m%d-%H%M%S)"
  fi
  run_as_user "$VENV_DIR/bin/python" - <<PY
from pathlib import Path
import yaml
p = Path(${REPO_DIR@Q}) / 'config.yaml'
data = yaml.safe_load(p.read_text(encoding='utf-8')) or {}
def section(name):
    value = data.get(name)
    if not isinstance(value, dict):
        value = {}
        data[name] = value
    return value
section('server').update({'host': ${HOST@Q}, 'port': int(${PORT@Q}), 'use_auth': False, 'use_ngrok': False, 'log_file_path': ${LOG_DIR@Q} + '/tts_server.log'})
section('model').update({'repo_id': 'chatterbox-multilingual'})
section('tts_engine').update({'device': 'cpu', 'predefined_voices_path': ${VOICES_DIR@Q}, 'reference_audio_path': ${REFERENCE_DIR@Q}})
section('paths').update({'model_cache': ${HF_CACHE@Q}, 'output': ${OUTPUT_DIR@Q}})
section('generation_defaults').update({'language': 'ru', 'exaggeration': 0.5, 'cfg_weight': 0.5, 'speed_factor': 1.0})
section('audio_output').update({'format': 'wav', 'save_to_disk': True})
section('ui').update({'show_language_select': True})
p.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding='utf-8')
PY
  chown "$RUN_USER:$RUN_USER" "$REPO_DIR/config.yaml"
}

install_service() {
  log "Installing systemd service"
  if [[ ! -f "$REPO_DIR/server.py" ]]; then
    echo "Entrypoint not found: $REPO_DIR/server.py. Project layout changed; cannot create service." >&2
    exit 1
  fi
  cat > /etc/systemd/system/${SERVICE_NAME} <<EOF_SERVICE
[Unit]
Description=Chatterbox TTS Server CPU
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_DIR}/bin/python server.py
Restart=on-failure
RestartSec=5
Environment=HF_HOME=${HF_CACHE}
Environment=TRANSFORMERS_CACHE=${HF_CACHE}
Environment=HF_HUB_CACHE=${HF_CACHE}
Environment=PYTHONUNBUFFERED=1
Environment=OMP_NUM_THREADS=${CPU_THREADS}
Environment=MKL_NUM_THREADS=${CPU_THREADS}

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
}

start_service() {
  if (( NO_START )); then
    log "Skipping service start (--no-start)"
    return
  fi
  log "Enabling and restarting service"
  systemctl enable chatterbox.service
  systemctl restart chatterbox.service
}

wait_http() {
  local url="$1" timeout="$2" start now code
  start=$(date +%s)
  while true; do
    code=$(curl -fsS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    [[ "$code" == "200" ]] && return 0
    now=$(date +%s)
    (( now - start >= timeout )) && return 1
    sleep 3
  done
}

health_check() {
  if (( NO_START )); then
    return
  fi
  log "Running health checks"
  systemctl is-active --quiet chatterbox.service
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${PORT}" | grep -q ":${PORT}"
  else
    curl -fsS "http://127.0.0.1:${PORT}/docs" >/dev/null
  fi
  local timeout=180
  (( PRELOAD_MODELS )) && timeout=1800
  wait_http "http://127.0.0.1:${PORT}/api/ui/initial-data" "$timeout"
  wait_http "http://127.0.0.1:${PORT}/docs" 60
}

server_ip() {
  hostname -I | awk '{print $1}'
}

main() {
  install_system_packages
  install_uv
  ensure_user_and_dirs
  sync_repo
  setup_python_and_deps
  patch_config
  install_service
  start_service
  health_check
  local ip
  ip="$(server_ip)"
  cat <<DONE

Chatterbox TTS установлен.
Web UI: http://${ip}:${PORT}
Swagger/API docs: http://${ip}:${PORT}/docs

Проверка:
sudo systemctl status chatterbox --no-pager
sudo journalctl -u chatterbox -f
curl http://127.0.0.1:${PORT}/api/ui/initial-data

Firewall не открыт автоматически. Если используете UFW, выполните:
sudo ufw allow ${PORT}/tcp
DONE
}

main "$@"
