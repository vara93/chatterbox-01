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
  const ruPresetCatalog = {
    '⚡ Turbo: Tech Support Meltdown': {title:'⚡ Турбо: Срыв в техподдержке', ex:0.75, cfg:0.30, speed:1.05, text:`— Спасибо, что позвонили в техподдержку. Вы пробовали выключить и включить устройство?
— Я пробовал всё. Даже разговаривал с роутером уважительно.
— Отлично, это уже продвинутый уровень диагностики. Теперь спокойно нажмите кнопку питания и не спорьте с принтером.`},
    '⚡ Turbo: The Overly Dramatic Chef': {title:'⚡ Турбо: Слишком драматичный шеф', ex:0.80, cfg:0.30, speed:1.05, text:`Дамы и господа, перед нами не просто суп. Это симфония моркови, лука и надежды. Одна лишняя щепотка соли — и судьба ужина повиснет на волоске.`},
    '⚡ Turbo: Conspiracy Podcast Host': {title:'⚡ Турбо: Ведущий конспирологического подкаста', ex:0.70, cfg:0.30, speed:1.00, text:`Друзья, задайте себе простой вопрос: почему чайник выключается именно тогда, когда вода закипела? Совпадение? Возможно. Но документы на кухонном столе говорят об обратном.`},
    '⚡ Turbo: First-Time Skydiver': {title:'⚡ Турбо: Первый прыжок с парашютом', ex:0.85, cfg:0.28, speed:1.08, text:`Так, я абсолютно спокоен. Просто земля почему-то стала очень далеко. Инструктор улыбается, значит всё хорошо. Если я кричу, это не страх, это проверка акустики неба.`},
    "⚡ Turbo: The Overworked Parent's Bedtime Story": {title:'⚡ Турбо: Уставший родитель читает сказку', ex:0.55, cfg:0.35, speed:0.95, text:`Жил-был маленький дракон, который никак не хотел спать. Он просил воды, потом сказку, потом ещё одну сказку. А мудрый родитель-дракон тихо сказал: «Сокровища подождут. Сейчас все закрывают глазки».`},
    '⚡ Turbo: Escape Room Panic': {title:'⚡ Турбо: Паника в квест-комнате', ex:0.80, cfg:0.28, speed:1.08, text:`У нас осталось восемь минут. На стене три ключа, под ковром записка, а кто-то уже пытается договориться с дверью. Спокойно. Дышим. Сначала читаем подсказку, потом паникуем по расписанию.`},
    '⚡ Turbo: Nature Documentary Narrator Gone Wrong': {title:'⚡ Турбо: Диктор природы пошёл не по плану', ex:0.65, cfg:0.32, speed:0.98, text:`Перед нами редчайшее создание — офисный сотрудник в понедельник утром. Он осторожно приближается к кофемашине, избегая зрительного контакта с календарём.`},
    '⚡ Turbo: The Emotional Movie Reviewer': {title:'⚡ Турбо: Эмоциональный кинокритик', ex:0.78, cfg:0.30, speed:1.00, text:`Этот фильм посмотрел прямо в мою душу, поправил там шторы и оставил записку. Сюжет местами спорный, но сцена с дождём — это чистая поэзия, снятая объективом сердца.`},
    '⚡ Turbo: Nervous Wedding Toast': {title:'⚡ Турбо: Нервный свадебный тост', ex:0.72, cfg:0.32, speed:1.02, text:`Дорогие друзья, я подготовил короткий тост на три страницы, но вижу ваши лица и буду импровизировать. Пусть в вашем доме всегда будет любовь, смех и зарядка для телефона в нужный момент.`},
    'Long Story Excerpt (Chunking Test)': {title:'Длинный рассказ для проверки фрагментов', ex:0.50, cfg:0.35, speed:0.95, text:`Глава первая. Дорога через сосновый лес казалась бесконечной. Снег мягко ложился на ветви, луна отражалась в колее, а старый почтовый фургон медленно поднимался к перевалу. Внутри сидела девочка с медным компасом в руках. Стрелка компаса указывала не на север, а туда, где её ждали ответы.`},
    'Noir Detective Monologue': {title:'Нуарный монолог детектива', ex:0.60, cfg:0.35, speed:0.92, text:`Дождь стучал по стеклу так, будто город пытался выбить признание. На моём столе лежала фотография, остывший кофе и дело, в котором слишком много людей говорили правду наполовину.`},
    "Children's Story Narrator": {title:'Рассказчик детской сказки', ex:0.55, cfg:0.35, speed:0.95, text:`На краю солнечной поляны жил маленький ёжик Тимоша. Он очень боялся темноты, пока однажды не понял: звёзды — это маленькие фонарики, которые ночь зажигает специально для смелых путешественников.`},
    'Motivational Speech': {title:'Мотивационная речь', ex:0.70, cfg:0.30, speed:1.00, text:`Сегодня не нужно быть идеальным. Достаточно сделать один честный шаг вперёд. Ошибки — это не стена, а лестница. Поднимайтесь спокойно, уверенно и не забывайте дышать.`},
    'Scientific Abstract Reading': {title:'Чтение научной аннотации', ex:0.45, cfg:0.40, speed:0.92, text:`В данной работе рассматривается влияние акустических признаков на устойчивость синтеза русской речи. Экспериментальные результаты показывают, что чистый reference audio и умеренные значения cfg_weight повышают разборчивость и стабильность генерации.`},
    'Fairy Tale Villain Monologue': {title:'Монолог сказочного злодея', ex:0.82, cfg:0.28, speed:0.96, text:`Вы думали, что замок заснул случайно? О нет. Это была моя колыбельная для целого королевства. Теперь даже часы шепчут моё имя, а луна прячется за башней.`}
  };
  const ruTemplates = Object.fromEntries(Object.entries(ruPresetCatalog).map(([key, value]) => [value.title, value]));
  function translateString(value) {
    if (!value) return value; const trimmed = value.trim();
    if (exact.has(trimmed)) return value.replace(trimmed, exact.get(trimmed));
    let out = value; for (const [from, to] of contains) out = out.split(from).join(to); return out;
  }
  function looksEnglishPreset(text) {
    if (!text) return false;
    const latin = (text.match(/[A-Za-z]/g) || []).length;
    const cyr = (text.match(/[А-Яа-яЁё]/g) || []).length;
    return latin > 80 && cyr < 10;
  }
  function setTextareaValue(textarea, value) {
    textarea.value = value;
    textarea.dispatchEvent(new Event('input', {bubbles: true}));
    textarea.dispatchEvent(new Event('change', {bubbles: true}));
  }
  function setControlByKeywords(keywords, value) {
    const inputs = document.querySelectorAll('input[type="range"], input[type="number"]');
    for (const input of inputs) {
      const context = `${input.name || ''} ${input.id || ''} ${input.getAttribute('aria-label') || ''} ${input.title || ''} ${input.closest('label, div, section')?.textContent || ''}`.toLowerCase();
      if (keywords.some(k => context.includes(k))) {
        input.value = String(value);
        input.dispatchEvent(new Event('input', {bubbles: true}));
        input.dispatchEvent(new Event('change', {bubbles: true}));
        return true;
      }
    }
    return false;
  }
  function applyRussianPreset(preset) {
    const textarea = document.querySelector('textarea');
    if (!textarea || !preset) return;
    setTextareaValue(textarea, preset.text);
    setControlByKeywords(['exaggeration', 'выраз'], preset.ex);
    setControlByKeywords(['cfg', 'cfg_weight'], preset.cfg);
    setControlByKeywords(['speed', 'скор'], preset.speed);
  }
  function presetForOption(option) {
    if (!option) return null;
    const original = option.dataset.originalPreset || option.textContent.trim();
    return ruPresetCatalog[original] || Object.values(ruPresetCatalog).find(p => p.title === option.textContent.trim()) || null;
  }
  function localizePresetSelects(root = document) {
    for (const select of (root.querySelectorAll ? root.querySelectorAll('select') : [])) {
      let hasPreset = false;
      for (const option of select.options || []) {
        const text = option.dataset.originalPreset || option.textContent.trim();
        if (ruPresetCatalog[text]) {
          option.dataset.originalPreset = text;
          option.textContent = ruPresetCatalog[text].title;
          hasPreset = true;
        }
      }
      if (hasPreset && !select.dataset.ruPresetBound) {
        select.dataset.ruPresetBound = '1';
        select.addEventListener('change', () => applyRussianPreset(presetForOption(select.selectedOptions[0])));
      }
    }
  }
  function ensureRussianTemplatesPanel(root = document) {
    const textarea = root.querySelector ? root.querySelector('textarea') : document.querySelector('textarea');
    if (!textarea || document.getElementById('chatterbox-ru-templates')) return;
    const wrap = document.createElement('div');
    wrap.id = 'chatterbox-ru-templates';
    wrap.style.cssText = 'margin:10px 0;padding:10px;border:1px solid #cbd5e1;border-radius:8px;background:#f8fafc;color:#0f172a;display:flex;gap:8px;align-items:center;flex-wrap:wrap';
    const label = document.createElement('strong'); label.textContent = 'Русские шаблоны:';
    const select = document.createElement('select'); select.style.cssText = 'padding:6px 10px;border:1px solid #94a3b8;border-radius:6px';
    for (const name of Object.keys(ruTemplates)) { const opt = document.createElement('option'); opt.value = name; opt.textContent = name; select.appendChild(opt); }
    const btn = document.createElement('button'); btn.type = 'button'; btn.textContent = 'Вставить шаблон'; btn.style.cssText = 'padding:7px 12px;border-radius:6px;border:0;background:#4f46e5;color:white;cursor:pointer';
    btn.addEventListener('click', () => applyRussianPreset(ruTemplates[select.value] || {text: ruText, ex: 0.5, cfg: 0.5, speed: 1.0}));
    wrap.append(label, select, btn);
    textarea.insertAdjacentElement('beforebegin', wrap);
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
      if (el.tagName === 'TEXTAREA') {
        if (!el.dataset.ruHintApplied || looksEnglishPreset(el.value)) setTextareaValue(el, ruText);
        el.placeholder = ruText; el.dataset.ruHintApplied = '1';
      }
    }
    localizePresetSelects(root);
    ensureRussianTemplatesPanel(root);
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
