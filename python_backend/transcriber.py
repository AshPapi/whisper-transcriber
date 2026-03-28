"""
TranscribeWorker — запускает ffmpeg + openai-whisper в отдельном потоке.
Сегменты передаются через on_segment callback по мере появления.
"""

import logging
import os
import subprocess
import tempfile
import threading
import traceback
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger("whisper-backend")


VIDEO_EXTENSIONS = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".ts", ".m4v"}


def fmt_time(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


class TranscribeWorker:
    def __init__(
        self,
        task_id: str,
        model_path: str,
        audio_path: str,
        language: Optional[str],
        beam_size: int,
        device: str,
        on_status: Callable[[str, str], None],    # (task_id, status_text)
        on_segment: Callable[[str, dict], None],   # (task_id, segment)
        on_finished: Callable[[str, list], None],  # (task_id, segments)
        on_error: Callable[[str, str], None],      # (task_id, error_msg)
    ):
        self.task_id = task_id
        self.model_path = model_path
        self.audio_path = audio_path
        self.language = language if language and language != "auto" else None
        self.beam_size = beam_size
        self.device = device
        self.on_status = on_status
        self.on_segment = on_segment
        self.on_finished = on_finished
        self.on_error = on_error
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self):
        self._thread = threading.Thread(target=self.run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def run(self):
        log.info("[%s] Task started: %s", self.task_id[:8], Path(self.audio_path).name)
        tmp_file = None
        try:
            # Ensure ffmpeg is available
            ffmpeg_bin = "ffmpeg"
            try:
                import static_ffmpeg
                static_ffmpeg.add_paths()
                # Get the actual binary path to avoid PATH lookup issues on Windows
                try:
                    ffmpeg_bin = static_ffmpeg.run.get_or_fetch_platform_executables_else_raise()[0]
                except Exception:
                    pass
            except ImportError:
                pass

            import whisper

            suffix = Path(self.audio_path).suffix.lower()
            self.on_status(
                self.task_id,
                "extracting_audio" if suffix in VIDEO_EXTENSIONS else "converting_audio",
            )

            # Use a short temp path to avoid issues with long/special-char paths on Windows
            tmp_fd, tmp_path = tempfile.mkstemp(suffix=".wav", dir=tempfile.gettempdir())
            os.close(tmp_fd)
            tmp_file = tmp_path

            result = subprocess.run(
                [
                    ffmpeg_bin, "-y", "-i", self.audio_path,
                    "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
                    tmp_path,
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            if result.returncode != 0:
                raise RuntimeError(f"ffmpeg error:\n{result.stderr[-500:]}")
            log.info("[%s] Audio converted to WAV: %s", self.task_id[:8], tmp_path)

            if self._stop.is_set():
                return

            import torch
            device = self.device

            if device.startswith("cuda"):
                if not torch.cuda.is_available():
                    device = "cpu"
                else:
                    n_gpus = torch.cuda.device_count()
                    if device == "cuda" or device == "cuda:auto":
                        # Auto-select GPU with the most VRAM
                        best = max(range(n_gpus),
                                   key=lambda i: torch.cuda.get_device_properties(i).total_memory)
                        device = f"cuda:{best}"
                    else:
                        # Validate specific cuda:N index
                        try:
                            idx = int(device.split(":")[1])
                            if idx >= n_gpus:
                                # Fallback to auto-select
                                best = max(range(n_gpus),
                                           key=lambda i: torch.cuda.get_device_properties(i).total_memory)
                                device = f"cuda:{best}"
                        except (ValueError, IndexError):
                            # Invalid format, auto-select
                            best = max(range(n_gpus),
                                       key=lambda i: torch.cuda.get_device_properties(i).total_memory)
                            device = f"cuda:{best}"

            self.on_status(self.task_id, f"loading_model:{device.upper()}")
            log.info("[%s] Loading model %s on %s", self.task_id[:8], self.model_path, device)
            try:
                model = whisper.load_model(self.model_path, device=device)
                log.info("[%s] Model loaded on %s", self.task_id[:8], device)
            except (RuntimeError, torch.cuda.OutOfMemoryError) as e:
                if device != "cpu" and ("memory" in str(e).lower() or "CUDA" in str(e)):
                    log.warning("[%s] Not enough VRAM (%s), falling back to CPU", self.task_id[:8], e)
                    device = "cpu"
                    self.on_status(self.task_id, "loading_model:CPU (VRAM недостаточно)")
                    torch.cuda.empty_cache()
                    model = whisper.load_model(self.model_path, device="cpu")
                    log.info("[%s] Model loaded on CPU (fallback)", self.task_id[:8])
                else:
                    raise

            if self._stop.is_set():
                return

            self.on_status(self.task_id, "transcribing")
            log.info("[%s] Transcribing, fp16=%s, lang=%s, beam=%s",
                     self.task_id[:8], device != "cpu", self.language, self.beam_size)

            all_segments = []

            fp16 = device != "cpu"
            try:
                result_data = model.transcribe(
                    tmp_path,
                    language=self.language,
                    beam_size=self.beam_size,
                    fp16=fp16,
                    verbose=False,
                )
            except RuntimeError as e:
                if "CUDA" in str(e) or "fp16" in str(e).lower():
                    result_data = model.transcribe(
                        tmp_path,
                        language=self.language,
                        beam_size=self.beam_size,
                        fp16=False,
                        verbose=False,
                    )
                else:
                    raise

            total_segs = len(result_data["segments"])
            for i, seg in enumerate(result_data["segments"]):
                if self._stop.is_set():
                    break
                segment = {
                    "id": seg["id"],
                    "start": seg["start"],
                    "end": seg["end"],
                    "text": seg["text"].strip(),
                }
                all_segments.append(segment)
                self.on_segment(self.task_id, segment)
                pct = int((i + 1) * 100 / total_segs) if total_segs > 0 else 0
                # Update progress every 5% to avoid flooding WebSocket
                if pct % 5 == 0 or i == total_segs - 1:
                    self.on_status(self.task_id, f"transcribing:{pct}")

            if not self._stop.is_set():
                log.info("[%s] Done: %d segments", self.task_id[:8], len(all_segments))
                self.on_finished(self.task_id, all_segments)
            else:
                log.info("[%s] Cancelled", self.task_id[:8])

        except InterruptedError:
            log.info("[%s] Interrupted", self.task_id[:8])
        except Exception as e:
            tb = traceback.format_exc()
            log.error("[%s] Error: %s\n%s", self.task_id[:8], e, tb)
            try:
                log_path = Path.home() / "whisper_error.log"
                log_path.write_text(tb, encoding="utf-8")
            except Exception:
                pass
            self.on_error(self.task_id, str(e))
        finally:
            # Free memory after task
            try:
                del model
            except Exception:
                pass
            try:
                import torch
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except Exception:
                pass
            import gc
            gc.collect()
            log.info("[%s] Memory freed", self.task_id[:8])
            if tmp_file and os.path.exists(tmp_file):
                os.remove(tmp_file)
