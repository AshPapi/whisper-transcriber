"""
Скрипт для скачивания моделей Whisper в формате faster-whisper (CTranslate2).
Запускать отдельно: python download_model.py

Доступные модели:
  tiny       ~150 MB  — самая лёгкая, для теста
  base       ~290 MB
  small      ~490 MB
  medium     ~1.5 GB
  large-v2   ~3.1 GB
  large-v3   ~3.1 GB
  turbo      ~1.6 GB  — whisper-large-v3-turbo, рекомендуется
"""

import sys
from pathlib import Path

MODELS_DIR = Path.home() / "whisper_models"

AVAILABLE = {
    "tiny":     "Systran/faster-whisper-tiny",
    "base":     "Systran/faster-whisper-base",
    "small":    "Systran/faster-whisper-small",
    "medium":   "Systran/faster-whisper-medium",
    "large-v2": "Systran/faster-whisper-large-v2",
    "large-v3": "Systran/faster-whisper-large-v3",
    "turbo":    "Systran/faster-whisper-large-v3-turbo",
}


def download(name: str):
    repo_id = AVAILABLE[name]
    dest = MODELS_DIR / name
    if dest.exists() and (dest / "model.bin").exists():
        print(f"Модель '{name}' уже скачана: {dest}")
        return

    print(f"Скачиваю '{name}' из {repo_id} в {dest} ...")
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print("Установите: pip install huggingface_hub")
        sys.exit(1)

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id=repo_id, local_dir=str(dest))
    print(f"Готово: {dest}")


def main():
    print("Доступные модели:")
    for k in AVAILABLE:
        marker = " ← рекомендуется" if k == "turbo" else ""
        print(f"  {k}{marker}")

    choice = input("\nВведите название модели (или Enter для 'turbo'): ").strip() or "turbo"
    if choice not in AVAILABLE:
        print(f"Неизвестная модель: {choice}")
        sys.exit(1)

    download(choice)


if __name__ == "__main__":
    main()
