#!/bin/bash
# Установка зависимостей для Whisper Transcriber
set -e

echo "=== Создание виртуального окружения ==="
python3 -m venv .venv
source .venv/bin/activate

echo "=== Обновление pip ==="
pip install --upgrade pip

echo "=== Установка PyTorch с CUDA (если есть NVIDIA GPU) ==="
# Для CUDA 12.x:
pip install torch --index-url https://download.pytorch.org/whl/cu121
# Если CUDA другой версии или нет GPU — замените на:
# pip install torch

echo "=== Установка зависимостей ==="
pip install -r requirements.txt
pip install huggingface_hub  # для download_model.py

echo ""
echo "=== Готово! ==="
echo ""
echo "Следующие шаги:"
echo "  1. Скачать модель:  python download_model.py"
echo "  2. Запустить:       python main.py"
echo ""
echo "Или быстрый запуск:"
echo "  source .venv/bin/activate && python main.py"
