# Whisper Transcriber — карта проекта

## Структура файлов

| Файл | Назначение |
|------|-----------|
| `main.py` | Точка входа. Весь UI (Flet) + логика транскрибации |
| `download_model.py` | CLI-скрипт для скачивания моделей вручную |
| `requirements.txt` | Зависимости Python |
| `run.bat` | Запуск приложения на Windows |
| `setup.bat` | Установка зависимостей на Windows |
| `download_model.bat` | Запуск download_model.py на Windows |
| `install.sh` | Установка зависимостей на Linux/Mac |
| `error.log` | Лог ошибок транскрибации (создаётся рядом с аудиофайлом) |
| `.github/workflows/build.yml` | CI/CD сборка |

## Архитектура main.py

| Строки | Что там |
|--------|---------|
| 1–35 | Импорты, UTF-8, ffmpeg init |
| 37–48 | Константы: папка моделей, список моделей, расширения видео, путь к настройкам |
| 50–64 | Цветовая палитра UI (Luminous Workspace) |
| 67–78 | `load_settings` / `save_settings` — JSON-файл `~/.whisper_transcriber.json` |
| 81–93 | Утилиты: `fmt_time`, `scan_models` (ищет `.pt` файлы) |
| 96–103 | `_default_device` — автодетект CUDA через torch |
| 106–186 | `TranscribeWorker` — поток транскрибации (ffmpeg → whisper.load_model → transcribe) |
| 188+ | `async main(page)` — весь UI на Flet |

## Ключевые зависимости

| Пакет | Роль |
|-------|------|
| `openai-whisper` | Транскрибация + загрузка моделей (тянет torch, numpy, tiktoken и др.) |
| `flet` | GUI-фреймворк (Flutter-based) |
| `numpy` | Работа с данными |
| `static-ffmpeg` | Встроенный ffmpeg если системный не найден |

## Модели Whisper

Скачиваются напрямую с CDN OpenAI (`openaipublic.azureedge.net`) — это официальные ссылки из `github.com/openai/whisper`.
Формат: `.pt` файлы (PyTorch checkpoint).
Сохраняются в `~/whisper_models/<name>.pt`.

URL берётся из `whisper._MODELS[name]` — всегда актуальные ссылки из установленной библиотеки.

| Модель | Размер |
|--------|--------|
| tiny | ~75 MB |
| base | ~145 MB |
| small | ~466 MB |
| medium | ~1.5 GB |
| large-v2 | ~2.9 GB |
| large-v3 | ~2.9 GB |
| turbo | ~1.5 GB |

## Загрузка моделей (UI)

- Используется `urllib.request.urlretrieve` с `reporthook` для отображения % прогресса
- `ft.ProgressBar.value` обновляется в диапазоне 0.0–1.0 из worker-треда
- При ошибке частично скачанный `.pt` файл удаляется

## Настройки пользователя

Хранятся в `~/.whisper_transcriber.json`:
- `models_dir` — путь к папке с моделями
- `device` — `cuda` или `cpu`
- `lang` — код языка или `auto`
- `beam` — beam size (по умолчанию 5)

## Транскрибация (TranscribeWorker)

1. ffmpeg конвертирует файл в WAV 16kHz mono
2. `whisper.load_model(path_to_pt, device=...)` загружает модель
3. `model.transcribe(wav_path, language=..., beam_size=..., fp16=...)` транскрибирует
4. `fp16=False` на CPU (важно для Windows — fp16 на CPU вызывает ошибку)
5. Сегменты: `result["segments"]` — список `{start, end, text}`

## Поддерживаемые форматы

**Видео:** `.mp4 .mkv .avi .mov .webm .flv .ts .m4v`
**Аудио:** всё что поддерживает ffmpeg (mp3, wav, ogg, flac и т.д.)

---
*Обновлять этот файл при каждом изменении структуры проекта.*
