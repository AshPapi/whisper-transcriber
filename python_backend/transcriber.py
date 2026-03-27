"""
TranscribeWorker — запускает ffmpeg + openai-whisper в отдельном потоке.
Сегменты передаются через on_segment callback по мере появления.
"""

import os
import subprocess
import tempfile
import threading
import traceback
from pathlib import Path
from typing import Callable, Optional


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
        tmp_file = None
        try:
            # Ensure ffmpeg is available
            try:
                import static_ffmpeg
                static_ffmpeg.add_paths()
            except ImportError:
                pass

            import whisper

            suffix = Path(self.audio_path).suffix.lower()
            self.on_status(
                self.task_id,
                "extracting_audio" if suffix in VIDEO_EXTENSIONS else "converting_audio",
            )

            tmp_fd, tmp_path = tempfile.mkstemp(suffix=".wav")
            os.close(tmp_fd)
            tmp_file = tmp_path

            result = subprocess.run(
                [
                    "ffmpeg", "-y", "-i", self.audio_path,
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

            if self._stop.is_set():
                return

            self.on_status(self.task_id, f"loading_model:{self.device.upper()}")
            model = whisper.load_model(self.model_path, device=self.device)

            if self._stop.is_set():
                return

            self.on_status(self.task_id, "transcribing:0")

            all_segments = []

            # Get duration for progress calculation
            import wave, contextlib
            duration = 0.0
            try:
                with contextlib.closing(wave.open(tmp_path, 'r')) as f:
                    duration = f.getnframes() / float(f.getframerate())
            except Exception:
                pass

            fp16 = (self.device != "cpu")
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
                self.on_status(self.task_id, f"transcribing:{pct}")

            if not self._stop.is_set():
                self.on_finished(self.task_id, all_segments)

        except InterruptedError:
            pass
        except Exception as e:
            log_path = Path(self.audio_path).parent / "error.log"
            try:
                log_path.write_text(traceback.format_exc(), encoding="utf-8")
            except Exception:
                Path.home().joinpath("whisper_error.log").write_text(
                    traceback.format_exc(), encoding="utf-8"
                )
            self.on_error(self.task_id, str(e))
        finally:
            if tmp_file and os.path.exists(tmp_file):
                os.remove(tmp_file)
