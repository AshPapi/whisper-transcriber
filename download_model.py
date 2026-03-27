"""
Скрипт для скачивания моделей Whisper (оригинальные .pt файлы от OpenAI).
Запускать отдельно: python download_model.py

Доступные модели:
  tiny       ~75 MB   — самая лёгкая, для теста
  base       ~145 MB
  small      ~466 MB
  medium     ~1.5 GB
  large-v2   ~2.9 GB
  large-v3   ~2.9 GB
  turbo      ~1.5 GB  — whisper-large-v3-turbo, рекомендуется
"""

import sys
import urllib.request
from pathlib import Path

MODELS_DIR = Path.home() / "whisper_models"


def _get_model_urls() -> dict:
    try:
        import whisper
        return dict(whisper._MODELS)
    except ImportError:
        print("Установите: pip install openai-whisper")
        sys.exit(1)


AVAILABLE = ["tiny", "base", "small", "medium", "large-v2", "large-v3", "turbo"]


def download(name: str):
    urls = _get_model_urls()
    url = urls.get(name)
    if not url:
        print(f"Неизвестная модель: {name}")
        sys.exit(1)

    dest = MODELS_DIR / f"{name}.pt"
    if dest.exists():
        print(f"Модель '{name}' уже скачана: {dest}")
        return

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Скачиваю '{name}' из {url}")
    print(f"Куда: {dest}")

    def _reporthook(count, block_size, total_size):
        if total_size > 0:
            pct = min(100, count * block_size * 100 // total_size)
            bar = "█" * (pct // 5) + "░" * (20 - pct // 5)
            print(f"\r  [{bar}] {pct}%", end="", flush=True)

    try:
        urllib.request.urlretrieve(url, str(dest), reporthook=_reporthook)
        print(f"\nГотово: {dest}")
    except Exception as ex:
        if dest.exists():
            dest.unlink()
        print(f"\nОшибка: {ex}")
        sys.exit(1)


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
