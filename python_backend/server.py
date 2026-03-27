"""
FastAPI backend для Whisper Transcriber.

Запуск:
    uvicorn server:app --host 127.0.0.1 --port 8765
"""

import asyncio
import json
import threading
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from model_manager import (
    list_models,
    download_model,
    delete_model,
    default_models_dir,
    default_device,
    model_path,
    scan_models,
)
from transcriber import TranscribeWorker

# ── ffmpeg ──────────────────────────────────────────────────────────────────
try:
    import static_ffmpeg
    static_ffmpeg.add_paths()
except ImportError:
    pass

# ── Settings ────────────────────────────────────────────────────────────────
import json as _json
SETTINGS_FILE = Path.home() / ".whisper_transcriber.json"

def _load_settings() -> dict:
    try:
        return _json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}

def _save_settings(data: dict):
    try:
        SETTINGS_FILE.write_text(_json.dumps(data), encoding="utf-8")
    except Exception:
        pass

_settings = _load_settings()

def _models_dir() -> str:
    return _settings.get("models_dir", str(default_models_dir()))

# ── App ─────────────────────────────────────────────────────────────────────
app = FastAPI(title="Whisper Transcriber Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── WebSocket hub ────────────────────────────────────────────────────────────
_ws_clients: set[WebSocket] = set()

async def _broadcast(event: dict):
    dead = set()
    for ws in _ws_clients:
        try:
            await ws.send_json(event)
        except Exception:
            dead.add(ws)
    _ws_clients.difference_update(dead)

def _broadcast_sync(event: dict):
    """Thread-safe broadcast из worker-треда."""
    loop = asyncio.get_event_loop()
    if loop.is_running():
        asyncio.run_coroutine_threadsafe(_broadcast(event), loop)

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    _ws_clients.add(ws)
    try:
        while True:
            await ws.receive_text()  # keep-alive
    except WebSocketDisconnect:
        _ws_clients.discard(ws)

# ── Models ───────────────────────────────────────────────────────────────────

@app.get("/models")
def get_models():
    return list_models(_models_dir())


class DownloadRequest(BaseModel):
    name: str

_download_stops: dict[str, threading.Event] = {}

@app.post("/models/download")
def start_download(req: DownloadRequest):
    name = req.name
    if name in _download_stops:
        raise HTTPException(400, "Already downloading")

    stop_event = threading.Event()
    _download_stops[name] = stop_event

    def _run():
        try:
            def on_progress(done, total, speed):
                pct = int(done * 100 / total) if total > 0 else 0
                _broadcast_sync({
                    "type": "download_progress",
                    "name": name,
                    "bytes_done": done,
                    "total": total,
                    "pct": pct,
                    "speed_mbs": round(speed, 2),
                })

            download_model(name, _models_dir(), on_progress, stop_event)
            _broadcast_sync({"type": "download_done", "name": name})
        except InterruptedError:
            _broadcast_sync({"type": "download_cancelled", "name": name})
        except Exception as e:
            _broadcast_sync({"type": "download_error", "name": name, "msg": str(e)})
        finally:
            _download_stops.pop(name, None)

    threading.Thread(target=_run, daemon=True).start()
    return {"status": "started", "name": name}


@app.delete("/models/download/{name}")
def cancel_download(name: str):
    ev = _download_stops.get(name)
    if ev:
        ev.set()
        return {"status": "cancelled"}
    raise HTTPException(404, "No active download for this model")


@app.delete("/models/{name}")
def remove_model(name: str):
    removed = delete_model(name, _models_dir())
    if not removed:
        raise HTTPException(404, "Model file not found")
    return {"status": "deleted", "name": name}

# ── Transcription queue ──────────────────────────────────────────────────────

class TranscribeRequest(BaseModel):
    files: list[str]
    model_name: str
    language: Optional[str] = "auto"
    beam_size: int = 5
    device: Optional[str] = None

_tasks: dict[str, dict] = {}          # task_id → task info
_workers: dict[str, TranscribeWorker] = {}
_task_queue: asyncio.Queue = None      # populated on startup

@app.on_event("startup")
async def _startup():
    global _task_queue
    _task_queue = asyncio.Queue()
    asyncio.create_task(_queue_runner())

async def _queue_runner():
    while True:
        task_id = await _task_queue.get()
        task = _tasks.get(task_id)
        if not task:
            continue
        worker = _workers.get(task_id)
        if not worker:
            continue
        worker.start()
        # wait for it to finish (or be cancelled)
        while task["status"] in ("queued", "running"):
            await asyncio.sleep(0.2)


def _on_status(task_id, status):
    if task_id in _tasks:
        _tasks[task_id]["status"] = "running"
        _tasks[task_id]["status_text"] = status
    _broadcast_sync({"type": "task_status", "task_id": task_id, "status": status})

def _on_segment(task_id, segment):
    if task_id in _tasks:
        _tasks[task_id]["segments"].append(segment)
    _broadcast_sync({"type": "segment", "task_id": task_id, "segment": segment})

def _on_finished(task_id, segments):
    if task_id in _tasks:
        _tasks[task_id]["status"] = "done"
        _tasks[task_id]["segments"] = segments
    _broadcast_sync({"type": "task_done", "task_id": task_id})

def _on_error(task_id, msg):
    if task_id in _tasks:
        _tasks[task_id]["status"] = "error"
        _tasks[task_id]["error"] = msg
    _broadcast_sync({"type": "task_error", "task_id": task_id, "msg": msg})


@app.post("/transcribe")
async def add_transcribe(req: TranscribeRequest):
    device = req.device or _settings.get("device") or default_device()
    mdir = _models_dir()

    # check model exists
    mpath = model_path(req.model_name, mdir)
    if not mpath.exists():
        raise HTTPException(400, f"Model '{req.model_name}' not downloaded")

    task_ids = []
    for file_path in req.files:
        if not Path(file_path).exists():
            raise HTTPException(400, f"File not found: {file_path}")

        task_id = str(uuid.uuid4())
        _tasks[task_id] = {
            "task_id": task_id,
            "file": file_path,
            "model": req.model_name,
            "status": "queued",
            "segments": [],
        }

        worker = TranscribeWorker(
            task_id=task_id,
            model_path=str(mpath),
            audio_path=file_path,
            language=req.language,
            beam_size=req.beam_size,
            device=device,
            on_status=_on_status,
            on_segment=_on_segment,
            on_finished=_on_finished,
            on_error=_on_error,
        )
        _workers[task_id] = worker
        await _task_queue.put(task_id)
        task_ids.append(task_id)

    return {"task_ids": task_ids}


@app.delete("/transcribe/{task_id}")
def cancel_task(task_id: str):
    worker = _workers.get(task_id)
    if not worker:
        raise HTTPException(404, "Task not found")
    worker.stop()
    if task_id in _tasks:
        _tasks[task_id]["status"] = "cancelled"
    return {"status": "cancelled"}


@app.get("/transcribe/{task_id}")
def get_task(task_id: str):
    task = _tasks.get(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    return task


@app.get("/transcribe/{task_id}/result")
def get_result(task_id: str):
    task = _tasks.get(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    return {"task_id": task_id, "segments": task.get("segments", [])}

# ── Settings ─────────────────────────────────────────────────────────────────

@app.get("/settings")
def get_settings():
    return {
        "models_dir": _models_dir(),
        "device": _settings.get("device", default_device()),
        "lang": _settings.get("lang", "auto"),
        "beam": _settings.get("beam", 5),
    }


class SettingsUpdate(BaseModel):
    models_dir: Optional[str] = None
    device: Optional[str] = None
    lang: Optional[str] = None
    beam: Optional[int] = None

@app.patch("/settings")
def update_settings(req: SettingsUpdate):
    global _settings
    if req.models_dir is not None:
        _settings["models_dir"] = req.models_dir
    if req.device is not None:
        _settings["device"] = req.device
    if req.lang is not None:
        _settings["lang"] = req.lang
    if req.beam is not None:
        _settings["beam"] = req.beam
    _save_settings(_settings)
    return get_settings()


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()  # required for PyInstaller on Windows
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765, reload=False, log_level="info")
