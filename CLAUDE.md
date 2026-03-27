# Whisper Transcriber v2 — карта проекта

## Архитектура

**Flutter (Dart) UI** + **Python FastAPI backend** (сайдкар на localhost:8765)

```
whisper-transcriber/
├── flutter_ui/                    # Flutter-приложение (Dart)
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart              # Точка входа, shell с NavigationRail
│       ├── models/models.dart     # Dart-модели: WhisperModel, Segment, TranscribeTask
│       ├── theme/app_theme.dart   # Dark/Light темы (Material 3)
│       ├── services/backend_service.dart  # HTTP + WebSocket клиент
│       └── screens/
│           ├── home_screen.dart          # Drag&drop, выбор файлов, настройки
│           ├── queue_screen.dart         # Очередь задач с прогрессом
│           ├── result_screen.dart        # Редактор сегментов, экспорт SRT/VTT/TXT
│           └── model_manager_screen.dart # Список моделей, скачивание, удаление
│
├── python_backend/                # Python сайдкар
│   ├── requirements.txt           # fastapi, uvicorn, openai-whisper, numpy, static-ffmpeg
│   ├── server.py                  # FastAPI + WebSocket hub, очередь задач
│   ├── transcriber.py             # TranscribeWorker (поток: ffmpeg → whisper)
│   └── model_manager.py           # list_models, download_model, delete_model
│
├── launcher/
│   ├── run.bat                    # Запуск backend + Flutter app (Windows)
│   ├── run.sh                     # Запуск backend + Flutter app (Linux/Mac)
│   └── setup.bat                  # Установка зависимостей + сборка Flutter
│
├── main.py                        # Старое Flet-приложение (не используется в v2)
├── download_model.py              # CLI-скрипт скачивания моделей
└── requirements.txt               # Зависимости старого Flet-приложения
```

## Коммуникация Flutter ↔ Python

**REST API** (`http://127.0.0.1:8765`):
- `GET /models` — список всех моделей
- `POST /models/download` — начать скачивание
- `DELETE /models/download/{name}` — отменить скачивание
- `DELETE /models/{name}` — удалить модель
- `POST /transcribe` — добавить файлы в очередь
- `DELETE /transcribe/{id}` — отменить задачу
- `GET /transcribe/{id}/result` — получить сегменты
- `GET /settings`, `PATCH /settings` — настройки

**WebSocket** (`ws://127.0.0.1:8765/ws`):
Стриминг событий:
```json
{"type": "download_progress", "name": "turbo", "pct": 42, "speed_mbs": 12.3}
{"type": "download_done", "name": "turbo"}
{"type": "task_status", "task_id": "...", "status": "transcribing"}
{"type": "segment", "task_id": "...", "segment": {"id":0,"start":0.0,"end":2.4,"text":"..."}}
{"type": "task_done", "task_id": "..."}
{"type": "task_error", "task_id": "...", "msg": "..."}
```

## Ключевые зависимости

### Python backend
| Пакет | Роль |
|-------|------|
| `fastapi` + `uvicorn` | HTTP + WebSocket сервер |
| `openai-whisper` | Транскрибация (тянет torch, tiktoken и др.) |
| `numpy` | Работа с данными |
| `static-ffmpeg` | Встроенный ffmpeg |

### Flutter UI
| Пакет | Роль |
|-------|------|
| `http` | REST запросы к backend |
| `web_socket_channel` | WebSocket подключение |
| `file_picker` | Выбор файлов + сохранение |
| `desktop_drop` | Drag & drop файлов |
| `provider` | State management |

## Транскрибация (TranscribeWorker)

1. `static_ffmpeg.add_paths()` — добавить встроенный ffmpeg
2. ffmpeg конвертирует файл в WAV 16kHz mono (`tempfile`)
3. `whisper.load_model(path, device=...)` загружает модель
4. `model.transcribe(wav, fp16=(device!="cpu"))` транскрибирует
5. `on_segment(task_id, segment)` вызывается для каждого сегмента → WebSocket → Flutter
6. `fp16=False` на CPU (важно для Windows)

## Модели Whisper

Хранятся в `~/whisper_models/<name>.pt`
URL берётся из `whisper._MODELS[name]` — официальные CDN ссылки от OpenAI.

| Модель | Размер |
|--------|--------|
| tiny   | ~75 MB |
| base   | ~145 MB |
| small  | ~466 MB |
| medium | ~1.5 GB |
| large-v2 | ~2.9 GB |
| large-v3 | ~2.9 GB |
| turbo  | ~1.5 GB (рекомендуется) |

## Настройки пользователя

Хранятся в `~/.whisper_transcriber.json`:
- `models_dir` — путь к папке с моделями
- `device` — `cuda` или `cpu`
- `lang` — код языка или `auto`
- `beam` — beam size (по умолчанию 5)

## Запуск (разработка)

```bash
# 1. Backend
cd python_backend
pip install -r requirements.txt
uvicorn server:app --host 127.0.0.1 --port 8765

# 2. Flutter UI
cd flutter_ui
flutter pub get
flutter run -d windows
```

## Сборка для production

```batch
launcher\setup.bat
launcher\run.bat
```

---
*Обновлять этот файл при каждом изменении структуры проекта.*
