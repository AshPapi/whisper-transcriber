"""
Управление моделями Whisper: список, скачивание, удаление.
"""

import sys
import urllib.request
import urllib.error
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


_model_urls_cache: dict = {}

def _get_model_urls() -> dict:
    global _model_urls_cache
    if _model_urls_cache:
        return _model_urls_cache
    try:
        import whisper
        _model_urls_cache = dict(whisper._MODELS)
        return _model_urls_cache
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
    # Prevent path traversal
    safe_name = Path(name).name
    if safe_name != name or '..' in name or '/' in name or '\\' in name:
        raise ValueError(f"Invalid model name: {name}")
    return Path(models_dir) / f"{safe_name}.pt"


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
    tmp_dest = dest_dir / f"{name}.pt.tmp"

    if dest.exists():
        return dest

    # Clean up leftover partial download
    if tmp_dest.exists():
        tmp_dest.unlink()

    try:
        import requests
        import certifi
        with requests.get(url, stream=True, timeout=(30, 60), verify=certifi.where()) as r:
            r.raise_for_status()
            total_size = int(r.headers.get('content-length', 0))
            bytes_done = 0
            block_size = 65536
            import time
            _overall_start = time.time()
            with open(tmp_dest, 'wb') as f:
                for chunk in r.iter_content(chunk_size=block_size):
                    if stop_event and stop_event.is_set():
                        raise InterruptedError("download cancelled")
                    if chunk:
                        f.write(chunk)
                        bytes_done += len(chunk)
                        elapsed = time.time() - _overall_start
                        speed = (bytes_done / elapsed / 1_048_576) if elapsed > 0.1 else 0.0
                        on_progress(bytes_done, total_size, speed)
        # Move completed download to final path
        import shutil
        if dest.exists():
            tmp_dest.unlink()
        else:
            shutil.move(str(tmp_dest), str(dest))
    except InterruptedError:
        if tmp_dest.exists():
            tmp_dest.unlink()
        raise
    except Exception:
        if tmp_dest.exists():
            tmp_dest.unlink()
        raise

    return dest


def delete_model(name: str, models_dir: str) -> bool:
    """Удаляет .pt файл модели. Возвращает True если файл был удалён."""
    dest = model_path(name, models_dir)
    if dest.exists():
        dest.unlink()
        return True
    return False
