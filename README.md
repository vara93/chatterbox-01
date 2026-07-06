# Chatterbox TTS Server CPU installer for Ubuntu 26.04

Этот репозиторий содержит production-ready Bash-скрипт `install_chatterbox_cpu.sh` для развёртывания локального **Chatterbox TTS Server** из проекта <https://github.com/devnen/Chatterbox-TTS-Server> на чистой Ubuntu 26.04 live-server amd64 без GPU.

Скрипт не пишет Web UI с нуля: используется штатный Web UI проекта Chatterbox-TTS-Server. После установки сервер слушает `0.0.0.0:8004`, поэтому Web UI доступен с другого компьютера в сети по адресу:

```text
http://SERVER_IP:8004
```

Swagger/API docs:

```text
http://SERVER_IP:8004/docs
```

Авторизация, HTTPS и Nginx по умолчанию не включаются.



## Важно: `git pull` не обновляет установленный сервис

Если вы обновили этот репозиторий командой `git pull`, это меняет только файлы installer-а в текущем каталоге, например `/tmp/chatterbox-01`. Уже запущенный сервис продолжает работать из `/opt/chatterbox/app/Chatterbox-TTS-Server` и старого venv, пока вы не примените installer повторно.

После каждого `git pull` выполняйте:

```bash
sudo bash install_chatterbox_cpu.sh --update
sudo systemctl restart chatterbox
sudo journalctl -u chatterbox -n 80 --no-pager
```

Только после этого применяются новые исправления: CPU `torch.load` patch, русификация Web UI, обновлённый systemd unit и зависимости.

## Русский интерфейс и что нажимать

Скрипт дополнительно применяет runtime-перевод Web UI на русский язык: основные кнопки, подписи, подсказки и стартовый текст в поле ввода становятся русскими. После обновления скрипта выполните `sudo bash install_chatterbox_cpu.sh --update` и обновите страницу в браузере через Ctrl+F5 / Shift+Reload. Если после обновления upstream-проекта часть новых элементов осталась на английском, это не влияет на генерацию: выберите модель **Chatterbox Multilingual (23 языка)**, вставьте русский текст и нажмите **«Сгенерировать речь»**.

Минимальный сценарий для русского voice cloning:

1. Откройте `http://SERVER_IP:8004`.
2. В **«Активная модель»** выберите **Chatterbox Multilingual (23 языка)**.
3. Вставьте русский текст в поле **«Текст для озвучки»**.
4. В **«Режим голоса»** выберите **«Клонирование голоса (reference audio)»**.
5. Загрузите WAV/MP3 с вашим голосом или заранее положите файл в `/opt/chatterbox/reference_audio`.
6. Оставьте `exaggeration=0.5`, `cfg_weight=0.5`, `speed_factor=1.0`.
7. Нажмите **«Сгенерировать речь»**. После генерации используйте кнопку **«Скачать»** в блоке готового аудио.



## Русские шаблоны в Web UI

Runtime-патч добавляет над полем ввода блок **«Русские шаблоны»**. Все шаблоны там уже на русском:

- **Стих** — короткое стихотворение для проверки интонации;
- **Сказка** — художественный абзац;
- **Диктор** — ровная дикторская проверка;
- **Диалог** — две реплики для проверки пауз;
- **Аудиокнига** — атмосферный narrating-текст;
- **Инструкция** — практический текст про reference audio и параметры.

Нажмите **«Вставить шаблон»**, затем **«Сгенерировать речь»**. Если upstream UI загрузит англоязычный preset, runtime-патч заменит его русским стартовым текстом.

## Шаблон русского стихотворения для теста

Вставьте этот текст в поле **«Текст для озвучки»** для первого теста русской речи:

```text
Берёзовый вечер над тихой рекой,
Ложится туман серебристой рукой.
И звёзды, как искры, в воде зажжены,
А ветер приносит дыханье весны.

Скажи это мягко, спокойно, тепло,
Как будто в душе зазвучало светло.
```

Для voice cloning загрузите reference audio с вашим голосом и выберите **«Клонирование голоса (reference audio)»**.

## Что устанавливается

Скрипт выполняет установку systemd + venv, без Docker:

- системные пакеты: `git`, `curl`, `ca-certificates`, `build-essential`, `pkg-config`, `ffmpeg`, `libsndfile1`, `jq`, `python3-venv`;
- `uv` в `/usr/local/bin/uv`;
- отдельный managed Python 3.10 через `uv`;
- виртуальное окружение Python 3.10 в `/opt/chatterbox/venv`;
- исходный проект в `/opt/chatterbox/app/Chatterbox-TTS-Server`;
- systemd unit `/etc/systemd/system/chatterbox.service`;
- системный пользователь `chatterbox` без интерактивного логина.

Системный Python Ubuntu не меняется: скрипт не трогает `/usr/bin/python3` и не использует `update-alternatives`.

## Каталоги

По умолчанию создаются:

```text
/opt/chatterbox
/opt/chatterbox/app
/opt/chatterbox/venv
/opt/chatterbox/hf-cache
/opt/chatterbox/output
/opt/chatterbox/voices
/opt/chatterbox/reference_audio
/var/log/chatterbox
```

Пользователь `chatterbox` получает права записи на cache/output/voices/reference_audio/logs и `config.yaml`.

## Установка

Скопируйте `install_chatterbox_cpu.sh` на сервер и выполните:

```bash
sudo bash install_chatterbox_cpu.sh
```

После успешной установки в конце будет напечатан URL вида:

```text
Chatterbox TTS установлен.
Web UI: http://SERVER_IP:8004
Swagger/API docs: http://SERVER_IP:8004/docs
```

Если используется UFW, порт нужно открыть вручную:

```bash
sudo ufw allow 8004/tcp
```

Скрипт специально не открывает firewall автоматически.

## Параметры скрипта

```bash
sudo bash install_chatterbox_cpu.sh [options]
```

Поддерживаемые параметры:

- `--host 0.0.0.0` — адрес прослушивания, по умолчанию `0.0.0.0`;
- `--port 8004` — порт Web UI/API, по умолчанию `8004`;
- `--install-dir /opt/chatterbox` — базовый каталог установки;
- `--reinstall` — удалить текущий checkout проекта и venv, затем установить заново;
- `--update` — обновить код и зависимости без удаления каталогов;
- `--no-start` — установить/обновить, но не запускать сервис;
- `--preload-models` — после запуска ждать дольше, чтобы первая загрузка/скачивание модели успели пройти health check.

Примеры:

```bash
sudo bash install_chatterbox_cpu.sh --port 8004 --host 0.0.0.0
sudo bash install_chatterbox_cpu.sh --update
sudo bash install_chatterbox_cpu.sh --reinstall
sudo bash install_chatterbox_cpu.sh --port 8010 --no-start
sudo bash install_chatterbox_cpu.sh --preload-models
```

Скрипт идемпотентный: повторный запуск обновляет существующий git checkout через `git pull --ff-only`, переиспользует Python 3.10 venv и заново применяет настройки. Перед изменением существующего `config.yaml` создаётся backup `config.yaml.backup.YYYYMMDD-HHMMSS`.

## Настройки по умолчанию

Скрипт patch/update-ит `config.yaml` аккуратно через Python/YAML и выставляет:

- `server.host: 0.0.0.0`;
- `server.port: 8004`;
- `tts_engine.device: cpu`;
- `model.repo_id: chatterbox-multilingual`;
- `generation_defaults.language: ru`;
- `audio_output.format: wav`;
- `audio_output.save_to_disk: true`;
- `tts_engine.reference_audio_path: /opt/chatterbox/reference_audio`;
- `tts_engine.predefined_voices_path: /opt/chatterbox/voices`;
- `paths.output: /opt/chatterbox/output`;
- `paths.model_cache: /opt/chatterbox/hf-cache`.

`save_to_disk: true` нужен, чтобы после генерации Web UI мог отдать файл на скачивание из output-каталога.

## Управление сервисом

Статус:

```bash
sudo systemctl status chatterbox --no-pager
```

Запуск:

```bash
sudo systemctl start chatterbox
```

Остановка:

```bash
sudo systemctl stop chatterbox
```

Перезапуск:

```bash
sudo systemctl restart chatterbox
```

Автозапуск включается автоматически:

```bash
sudo systemctl enable chatterbox
```

Отключить автозапуск:

```bash
sudo systemctl disable chatterbox
```

Логи в реальном времени:

```bash
sudo journalctl -u chatterbox -f
```

Файловые логи приложения пишутся в `/var/log/chatterbox/tts_server.log`, если текущая версия Chatterbox-TTS-Server использует этот параметр `config.yaml`.

## Обновление

Обновить код проекта и зависимости:

```bash
sudo bash install_chatterbox_cpu.sh --update
```

Обычный повторный запуск без `--reinstall` тоже безопасен и делает `git pull --ff-only`.

## Переустановка

Полностью пересоздать checkout проекта и virtualenv:

```bash
sudo bash install_chatterbox_cpu.sh --reinstall
```

Каталоги `/opt/chatterbox/hf-cache`, `/opt/chatterbox/output`, `/opt/chatterbox/voices` и `/opt/chatterbox/reference_audio` не удаляются этим флагом.

## Reference audio и voice cloning

Voice cloning поддерживается штатным Web UI проекта. Если UI текущей версии позволяет загрузить reference audio, загрузите WAV/MP3 прямо через интерфейс.

Также можно положить файлы вручную:

```bash
sudo cp my_voice.wav /opt/chatterbox/reference_audio/
sudo chown chatterbox:chatterbox /opt/chatterbox/reference_audio/my_voice.wav
```

Рекомендации к reference audio:

- WAV или MP3;
- 5–15 секунд чистого голоса;
- один говорящий;
- без музыки;
- без шума;
- без реверберации;
- для русского голоса reference audio желательно тоже на русском.

## Стартовые рекомендации для русской озвучки

В Web UI начните с таких параметров:

- engine/model: **Chatterbox Multilingual**;
- language: `ru`;
- voice mode: **Voice Cloning**;
- temperature: default;
- exaggeration: `0.5`;
- cfg_weight: `0.5`;
- speed_factor: `1.0`;
- seed: фиксируйте число, если нужна повторяемость результата.

Если речь слишком быстрая или нестабильная:

- попробуйте `cfg_weight` около `0.3`;
- оставьте `exaggeration` около `0.5`.

Если нужна более выразительная речь:

- попробуйте `exaggeration` около `0.7`;
- попробуйте `cfg_weight` около `0.3`.

## Скачивание результата из Web UI

Штатный Web UI Chatterbox-TTS-Server содержит audio player и кнопку/ссылку скачивания результата после генерации. Скрипт включает сохранение на диск и монтирование output-каталога проекта через настройки сервера, поэтому сгенерированный WAV должен быть доступен для скачивания в интерфейсе после завершения генерации.

## Проверка API

Проверить, что UI/API поднялись:

```bash
curl http://127.0.0.1:8004/api/ui/initial-data
curl -I http://127.0.0.1:8004/docs
```

Пример TTS-запроса зависит от текущей схемы API проекта. Базовый endpoint `/tts` и Swagger доступны в `/docs`, где можно увидеть актуальные поля запроса для установленной версии.

## Производительность CPU

На CPU генерация может быть медленной. 20 vCPU и 10 GB RAM должны позволить работать, но:

- первый запуск будет долгим из-за скачивания модели с Hugging Face;
- первая генерация будет дольше последующих, потому что модель скачивается и загружается;
- для длинных текстов используйте chunking;
- если не хватает RAM или процесс убивается OOM, уменьшите chunk size;
- CPU-only режим ожидаемо медленнее GPU.

## Удаление сервиса и файлов

Остановить и отключить сервис:

```bash
sudo systemctl stop chatterbox || true
sudo systemctl disable chatterbox || true
sudo rm -f /etc/systemd/system/chatterbox.service
sudo systemctl daemon-reload
```

Удалить файлы установки:

```bash
sudo rm -rf /opt/chatterbox /var/log/chatterbox
```

Удалить пользователя:

```bash
sudo userdel chatterbox || true
```

Если `uv` больше не нужен:

```bash
sudo rm -f /usr/local/bin/uv /usr/local/bin/uvx
```

## Возможные проблемы

### Python 3.10 обязателен

Chatterbox-TTS-Server указывает Python 3.10 как обязательный из-за совместимости бинарных wheels для PyTorch/ONNX и связанных библиотек. Скрипт ставит изолированный Python 3.10 через `uv` и не меняет системный Python Ubuntu.



### `TypeError: 'NoneType' object is not callable` на `PerthImplicitWatermarker()`

Это проблема optional audio watermarking-библиотеки `perth`: на некоторых Linux CPU окружениях `perth.PerthImplicitWatermarker` импортируется как `None`. Скрипт исправляет это через `sitecustomize.py`: если implicit watermarker недоступен, используется `perth.DummyWatermarker`, чтобы модель могла загрузиться и генерировать речь. После обновления выполните:

```bash
sudo bash install_chatterbox_cpu.sh --update
sudo systemctl restart chatterbox
```

### `RuntimeError: Attempting to deserialize object on a CUDA device`

На CPU-only машине multilingual checkpoint может содержать CUDA storage tags. Скрипт ставит `sitecustomize.py` в venv, который на CPU автоматически добавляет `map_location=torch.device("cpu")` для `torch.load`, и systemd дополнительно получает `CUDA_VISIBLE_DEVICES=-1`. После обновления выполните:

```bash
sudo bash install_chatterbox_cpu.sh --update
sudo systemctl restart chatterbox
```

### `ImportError: cannot import name 'builder' from 'google.protobuf.internal'`

Это означает, что в venv попала слишком новая major-версия `protobuf`, несовместимая с `onnx==1.16.0`. Актуальный скрипт фиксирует это автоматически и устанавливает `protobuf==3.20.3`. Для уже установленного окружения можно выполнить:

```bash
sudo -u chatterbox /opt/chatterbox/venv/bin/python -m pip install --upgrade --no-warn-conflicts 'protobuf==3.20.3' pre-commit
sudo systemctl restart chatterbox
```

### `libsndfile` error

Убедитесь, что установлен пакет:

```bash
sudo apt-get install -y libsndfile1
```

Скрипт устанавливает его автоматически.

### Model download fails

Проверьте интернет и доступ к Hugging Face:

```bash
curl -I https://huggingface.co/
```

Также проверьте свободное место в `/opt/chatterbox/hf-cache`.

### Port already in use

Проверьте занятость порта:

```bash
sudo ss -ltnp 'sport = :8004'
```

Запустите установку с другим портом:

```bash
sudo bash install_chatterbox_cpu.sh --port 8010
```

### Permission denied на config/output/reference_audio

Восстановите владельца:

```bash
sudo chown -R chatterbox:chatterbox /opt/chatterbox /var/log/chatterbox
```

### CPU медленно

Это ожидаемо. Уменьшите длину текста/chunk size, используйте фиксированный seed для повторяемости и избегайте слишком длинных генераций одним запросом.

## Docker

Docker у upstream-проекта есть как альтернатива, но этот installer намеренно использует systemd + venv + Python 3.10 через `uv`, как более прямой вариант для локального сервера на Ubuntu без GPU.
