"""
Управление моделями Whisper: список, скачивание, удаление.
"""

import sys
import urllib.request
from pathlib import Path
from typing import Callable, Optional


WHISPER_MODELS = [
    ("tiny",     "~75 MB",   75),
    ("base",     "~145 MB",  145),
    ("small",    "~466 MB",  466),
    ("medium",   "~1.5 GB",  1500),
    ("large-v2", "~2.9 GB",  2900),
    ("large-v3", "~2.9 GB",  2900),
    ("turbo",    "~1.5 GB",  1500),
]


def _get_model_urls() -> dict:
    try:
        import whisper
        return dict(whisper._MODELS)
    except ImportError:
        return {}


def default_models_dir() -> Path:
    return Path.home() / "whisper_models"


def scan_models(models_dir: str) -> list[str]:
    """Возвращает список имён скачанных моделей (.pt файлы)."""
    p = Path(models_dir)
    if not p.exists():
        return []
    return [item.stem for item in sorted(p.glob("*.pt"))]


def model_path(name: str, models_dir: str) -> Path:
    return Path(models_dir) / f"{name}.pt"


def default_device() -> str:
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def list_models(models_dir: str) -> list[dict]:
    """Полный список моделей с статусом."""
    downloaded = set(scan_models(models_dir))
    result = []
    for name, size_label, size_mb in WHISPER_MODELS:
        result.append({
            "name": name,
            "size_label": size_label,
            "size_mb": size_mb,
            "downloaded": name in downloaded,
            "path": str(model_path(name, models_dir)) if name in downloaded else None,
        })
    return result


def download_model(
    name: str,
    models_dir: str,
    on_progress: Callable[[int, int, float], None],  # (bytes_done, total, speed_mbs)
    stop_event=None,
) -> Path:
    """
    Скачивает модель. on_progress вызывается периодически.
    Возвращает Path к скачанному файлу.
    """
    urls = _get_model_urls()
    url = urls.get(name)
    if not url:
        raise ValueError(f"Unknown model: {name}")

    dest_dir = Path(models_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{name}.pt"

    if dest.exists():
        return dest

    import time
    _start_time = [time.time()]
    _last_bytes = [0]

    def _reporthook(count, block_size, total_size):
        if stop_event and stop_event.is_set():
            raise InterruptedError("download cancelled")
        bytes_done = min(count * block_size, total_size) if total_size > 0 else count * block_size
        now = time.time()
        elapsed = now - _start_time[0]
        delta_bytes = bytes_done - _last_bytes[0]
        speed = (delta_bytes / elapsed / 1_048_576) if elapsed > 0 else 0.0
        _start_time[0] = now
        _last_bytes[0] = bytes_done
        on_progress(bytes_done, total_size, speed)

    try:
        urllib.request.urlretrieve(url, str(dest), reporthook=_reporthook)
    except InterruptedError:
        if dest.exists():
            dest.unlink()
        raise
    except Exception:
        if dest.exists():
            dest.unlink()
        raise

    return dest


def delete_model(name: str, models_dir: str) -> bool:
    """Удаляет .pt файл модели. Возвращает True если файл был удалён."""
    dest = model_path(name, models_dir)
    if dest.exists():
        dest.unlink()
        return True
    return False
