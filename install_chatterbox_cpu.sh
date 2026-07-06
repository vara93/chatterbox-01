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

restore_russian_ui_patch_before_pull() {
  [[ -d "$REPO_DIR/.git" ]] || return 0
  while IFS= read -r rel_path; do
    [[ -n "$rel_path" && -f "$REPO_DIR/$rel_path" ]] || continue
    if grep -q "CHATTERBOX_RU_UI_PATCH" "$REPO_DIR/$rel_path"; then
      run_as_user git -C "$REPO_DIR" checkout -- "$rel_path"
    fi
  done < <(run_as_user git -C "$REPO_DIR" diff --name-only -- '*.html' || true)
}

sync_repo() {
  log "Installing/updating Chatterbox-TTS-Server"
  if (( REINSTALL )); then
    rm -rf "$REPO_DIR" "$VENV_DIR"
  fi
  if [[ -d "$REPO_DIR/.git" ]]; then
    restore_russian_ui_patch_before_pull
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
  run_as_user "$VENV_DIR/bin/python" -m pip install --upgrade --no-warn-conflicts 'protobuf==3.20.3' pre-commit
  run_as_user "$VENV_DIR/bin/python" - <<'PY_CHECK'
import google.protobuf.internal.builder  # noqa: F401
import onnx  # noqa: F401
import s3tokenizer  # noqa: F401
import chatterbox  # noqa: F401
PY_CHECK
}

install_cpu_torch_load_patch() {
  log "Installing CPU torch.load compatibility patch"
  local sitecustomize_path
  sitecustomize_path="$(run_as_user "$VENV_DIR/bin/python" - <<'PY_SITE_PATH'
from pathlib import Path
import site
print(Path(site.getsitepackages()[0]) / 'sitecustomize.py')
PY_SITE_PATH
)"
  run_as_user tee "$sitecustomize_path" >/dev/null <<'PY_SITE'
"""CPU-only compatibility patch for Chatterbox checkpoints saved with CUDA storage tags."""
import functools

try:
    import torch
except Exception:  # keep interpreter startup safe
    torch = None

if torch is not None and not torch.cuda.is_available() and not getattr(torch.load, "_chatterbox_cpu_patch", False):
    _original_torch_load = torch.load

    @functools.wraps(_original_torch_load)
    def _torch_load_cpu_default(*args, **kwargs):
        kwargs.setdefault("map_location", torch.device("cpu"))
        return _original_torch_load(*args, **kwargs)

    _torch_load_cpu_default._chatterbox_cpu_patch = True
    torch.load = _torch_load_cpu_default

try:
    import perth
except Exception:
    perth = None

if perth is not None and getattr(perth, "PerthImplicitWatermarker", None) is None and hasattr(perth, "DummyWatermarker"):
    perth.PerthImplicitWatermarker = perth.DummyWatermarker
PY_SITE
  run_as_user "$VENV_DIR/bin/python" - <<'PY_CPU_CHECK'
import torch
assert not torch.cuda.is_available(), "CUDA unexpectedly visible on CPU installer"
assert getattr(torch.load, "_chatterbox_cpu_patch", False), "CPU torch.load patch was not activated"
import perth
assert perth.PerthImplicitWatermarker is not None, "Perth watermarker fallback was not activated"
PY_CPU_CHECK
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
data['device'] = 'cpu'
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

apply_russian_ui_patch() {
  log "Applying Russian Web UI translation patch"
  (cd "$REPO_DIR" && run_as_user "$VENV_DIR/bin/python" - <<'PY_RU_UI'
from pathlib import Path
repo = Path.cwd()
marker = "CHATTERBOX_RU_UI_PATCH"
script = """
<script id="chatterbox-ru-ui-patch">
/* CHATTERBOX_RU_UI_PATCH: runtime Russian localization for Chatterbox Web UI */
(() => {
  const exact = new Map(Object.entries({
    'Original': 'Оригинальная', 'API Docs': 'API-документация',
    'Configuration saved. Please restart the server manually for changes to take effect.': 'Конфигурация сохранена. Перезапустите сервер, чтобы изменения вступили в силу.',
    'Generate Speech': 'Сгенерировать речь', 'Active Model:': 'Активная модель:',
    'Text to synthesize': 'Текст для озвучки',
    'Enter the text you want to convert to speech. You can use emotion tags like [laugh], [sigh], etc.': 'Введите русский текст для озвучки. Для клонирования голоса используйте чистый reference audio.',
    'Split text into chunks': 'Разбивать текст на фрагменты', 'Chunk Size:': 'Размер фрагмента:',
    'Voice Mode:': 'Режим голоса:', 'Predefined Voices': 'Готовые голоса',
    'Voice Cloning (Reference)': 'Клонирование голоса (reference audio)',
    'Select Predefined Voice:': 'Выберите готовый голос:', '-- Select Voice --': '-- Выберите голос --',
    'Import': 'Импорт', 'Refresh': 'Обновить', 'Load Example Preset:': 'Загрузить пример:',
    'Generated Audio': 'Готовое аудио', 'Download': 'Скачать', 'Seed': 'Seed', 'Random': 'Случайно',
    'Temperature': 'Температура', 'Exaggeration': 'Выразительность', 'CFG Weight': 'CFG weight',
    'Speed Factor': 'Скорость', 'Language': 'Язык', 'Output Format': 'Формат файла',
    'Saving...': 'Сохранение...', 'Saving configuration...': 'Сохранение конфигурации...',
    'Save': 'Сохранить', 'Cancel': 'Отмена', 'Close': 'Закрыть'
  }));
  const contains = [
    ['Characters', 'символов'],
    ['Splitting is essential for longer texts like articles or audiobook chapters. Recommended chunk size ~150-400 characters.', 'Для длинных текстов включите разбиение на фрагменты. Рекомендуемый размер ~150–400 символов.'],
    ['This may take some time', 'Это может занять некоторое время'], ['Generating audio', 'Генерация аудио'],
    ['Chatterbox Multilingual (23 Languages)', 'Chatterbox Multilingual (23 языка)'],
    ['Chatterbox Original (English)', 'Chatterbox Original (английский)'],
    ['Chatterbox Turbo (Fast, English)', 'Chatterbox Turbo (быстрый, английский)']
  ];
  const ruText = `Берёзовый вечер над тихой рекой,
Ложится туман серебристой рукой.
И звёзды, как искры, в воде зажжены,
А ветер приносит дыханье весны.

Скажи это мягко, спокойно, тепло,
Как будто в душе зазвучало светло.`;
  function translateString(value) {
    if (!value) return value; const trimmed = value.trim();
    if (exact.has(trimmed)) return value.replace(trimmed, exact.get(trimmed));
    let out = value; for (const [from, to] of contains) out = out.split(from).join(to); return out;
  }
  function localize(root = document) {
    document.title = 'Chatterbox TTS Server — русская озвучка';
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {acceptNode(node) {
      const parent = node.parentElement;
      if (!parent || ['SCRIPT','STYLE','TEXTAREA'].includes(parent.tagName)) return NodeFilter.FILTER_REJECT;
      return node.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }});
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) { const next = translateString(node.nodeValue); if (next !== node.nodeValue) node.nodeValue = next; }
    for (const el of root.querySelectorAll ? root.querySelectorAll('input, textarea, button, option, [title], [aria-label], [placeholder]') : []) {
      for (const attr of ['title','aria-label','placeholder','value']) if (el.hasAttribute && el.hasAttribute(attr)) {
        const next = translateString(el.getAttribute(attr)); if (next !== el.getAttribute(attr)) el.setAttribute(attr, next);
      }
      if (el.tagName === 'TEXTAREA' && !el.dataset.ruHintApplied) {
        if (!el.value || /This room smells|Hello|Enter the text/i.test(el.value)) el.value = ruText;
        el.placeholder = ruText; el.dataset.ruHintApplied = '1'; el.dispatchEvent(new Event('input', {bubbles: true}));
      }
    }
  }
  const run = () => localize(document); if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
  new MutationObserver(muts => { for (const mut of muts) for (const node of mut.addedNodes) if (node.nodeType === 1) localize(node); }).observe(document.documentElement, {childList: true, subtree: true});
})();
</script>
"""
for html in repo.rglob('*.html'):
    if any(part in {'.git', 'venv', '__pycache__'} for part in html.parts):
        continue
    text = html.read_text(encoding='utf-8')
    if marker in text:
        continue
    lower = text.lower()
    if '</body>' in lower:
        idx = lower.rfind('</body>')
        text = text[:idx] + script + '\n' + text[idx:]
    else:
        text += '\n' + script + '\n'
    html.write_text(text, encoding='utf-8')
PY_RU_UI
)
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
Environment=CUDA_VISIBLE_DEVICES=-1
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


wait_port() {
  local timeout="$1" start now
  start=$(date +%s)
  while true; do
    if command -v ss >/dev/null 2>&1; then
      if ss -ltn "sport = :${PORT}" | awk 'NR > 1 {found=1} END {exit found ? 0 : 1}'; then
        return 0
      fi
    elif curl -fsS --connect-timeout 2 "http://127.0.0.1:${PORT}/docs" >/dev/null 2>&1; then
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      echo "Port ${PORT} did not start listening within ${timeout}s" >&2
      systemctl status chatterbox.service --no-pager >&2 || true
      journalctl -u chatterbox.service -n 80 --no-pager >&2 || true
      return 1
    fi
    sleep 3
  done
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
  local timeout=180
  (( PRELOAD_MODELS )) && timeout=1800
  wait_port "$timeout"
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
  install_cpu_torch_load_patch
  patch_config
  apply_russian_ui_patch
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
