# Whisper Transcriber

Десктопное приложение для транскрибации аудио и видео файлов с помощью [OpenAI Whisper](https://github.com/openai/whisper).

## Возможности

- Перетаскивание файлов (drag & drop)
- Поддержка аудио: MP3, WAV, OGG, FLAC, M4A, AAC, WMA, OPUS
- Поддержка видео: MP4, MKV, AVI, MOV, WEBM, FLV, TS, M4V
- GPU (CUDA) и CPU режимы — автовыбор лучшего GPU
- Автоматический переход на CPU если не хватает VRAM
- Скачивание и удаление моделей прямо из приложения
- Экспорт результатов в SRT, VTT, TXT
- 16 языков + автоопределение

## Скачать и запустить

1. Скачать архив с [последнего релиза](https://github.com/AshPapi/whisper-transcriber/releases/latest)
2. Распаковать в любую папку
3. Запустить `whisper_transcriber.exe`
4. В приложении скачать нужную модель (раздел "Модели")
5. Добавить файл и нажать "Транскрибировать"

> Интернет нужен только для первоначального скачивания модели.

## Модели

| Модель | Размер | VRAM | Качество |
|--------|--------|------|----------|
| tiny | ~75 MB | 1 GB | Базовое |
| base | ~145 MB | 1 GB | Среднее |
| small | ~466 MB | 2 GB | Хорошее |
| medium | ~1.5 GB | 5 GB | Очень хорошее |
| turbo | ~1.5 GB | 6 GB | Отличное (рекомендуется) |
| large-v2 | ~2.9 GB | 10 GB | Лучшее |
| large-v3 | ~2.9 GB | 10 GB | Лучшее |

Если модель не влезает в VRAM видеокарты — автоматически используется CPU и оперативная память.

**Рекомендации:**
- 4 GB VRAM → `small` на GPU
- 8 GB VRAM → `turbo` на GPU
- 16+ GB VRAM → `large-v3` на GPU

## Запуск для разработчиков

### Требования
- Python 3.11+
- Flutter 3.x
- NVIDIA GPU с CUDA (опционально)

### Backend
```bash
cd python_backend
pip install -r requirements.txt
python server.py
```

### Frontend
```bash
cd flutter_ui
flutter pub get
flutter run -d windows
```

## Архитектура

Flutter UI + Python FastAPI backend на `localhost:8765`. Общение через REST API и WebSocket.
