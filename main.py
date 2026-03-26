import sys
import os
import locale
import threading
import json
import tempfile
import subprocess
from pathlib import Path

# UTF-8
if sys.stdout.encoding != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
if sys.stderr.encoding != "utf-8":
    sys.stderr.reconfigure(encoding="utf-8")
os.environ.setdefault("PYTHONUTF8", "1")
if hasattr(locale, "LC_MESSAGES"):
    os.environ["LC_MESSAGES"] = "C"
    locale.setlocale(locale.LC_MESSAGES, "C")

import flet as ft


def _ensure_ffmpeg():
    import shutil
    if shutil.which("ffmpeg"):
        return
    try:
        import static_ffmpeg
        static_ffmpeg.add_paths()
    except Exception:
        pass


_ensure_ffmpeg()

DEFAULT_MODELS_DIR = str(Path.home() / "whisper_models")

WHISPER_MODELS = [
    ("tiny",     "~75 MB"),
    ("base",     "~145 MB"),
    ("small",    "~466 MB"),
    ("medium",   "~1.5 GB"),
    ("large-v3", "~3 GB"),
]

VIDEO_EXTENSIONS = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".ts", ".m4v"}
SETTINGS_FILE = Path.home() / ".whisper_transcriber.json"

# ── Luminous Workspace palette ─────────────────────────────────────────────
C_BG                = "#f9f9f9"
C_CONTAINER         = "#eceeee"
C_CONTAINER_LOW     = "#f3f4f4"
C_CONTAINER_HIGH    = "#e6e9e9"
C_CONTAINER_HIGHEST = "#dfe3e4"
C_WHITE             = "#ffffff"
C_PRIMARY           = "#005fb2"
C_PRIMARY_DIM       = "#00539d"
C_ON_PRIMARY        = "#f8f8ff"
C_ON_SURFACE        = "#2f3334"
C_ON_SURFACE_VAR    = "#5b6061"
C_SECONDARY         = "#50616d"
C_OUTLINE_VAR       = "#afb3b3"
CS = ft.ControlState


def load_settings() -> dict:
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_settings(data: dict):
    try:
        SETTINGS_FILE.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass


def fmt_time(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def scan_models(models_dir: str) -> list:
    p = Path(models_dir)
    if not p.exists():
        return []
    found = []
    for item in sorted(p.iterdir()):
        if item.is_dir() and (item / "model.bin").exists():
            found.append((item.name, str(item)))
    for item in sorted(p.glob("*.bin")):
        found.append((item.stem, str(item)))
    return found


def _default_device() -> str:
    try:
        import ctranslate2
        if "cuda" in ctranslate2.get_supported_compute_types("cuda"):
            return "cuda"
    except Exception:
        pass
    return "cpu"


class TranscribeWorker(threading.Thread):
    def __init__(self, model_path, audio_path, language, beam_size, device,
                 on_progress, on_finished, on_error):
        super().__init__(daemon=True)
        self.model_path = model_path
        self.audio_path = audio_path
        self.language = language if language != "auto" else None
        self.beam_size = int(beam_size)
        self.device = device
        self.on_progress = on_progress
        self.on_finished = on_finished
        self.on_error = on_error
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    def run(self):
        import soundfile as sf
        tmp_file = None
        try:
            from faster_whisper import WhisperModel

            suffix = Path(self.audio_path).suffix.lower()
            self.on_progress(
                "извлечение аудио..." if suffix in VIDEO_EXTENSIONS else "конвертация аудио..."
            )
            tmp_fd, tmp_path = tempfile.mkstemp(suffix=".wav")
            os.close(tmp_fd)
            tmp_file = tmp_path

            result = subprocess.run(
                ["ffmpeg", "-y", "-i", self.audio_path,
                 "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", tmp_path],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
            )
            if result.returncode != 0:
                raise RuntimeError(f"ffmpeg error:\n{result.stderr[-500:]}")

            if self._stop.is_set():
                return

            self.on_progress(f"загрузка модели · {self.device.upper()}...")
            compute_type = "float16" if self.device == "cuda" else "int8"
            model = WhisperModel(self.model_path, device=self.device, compute_type=compute_type)

            if self._stop.is_set():
                return

            audio_array, _ = sf.read(tmp_path, dtype="float32")

            self.on_progress("транскрибация...")
            segments, info = model.transcribe(
                audio_array,
                language=self.language,
                beam_size=self.beam_size,
                vad_filter=True,
            )

            lines = []
            for seg in segments:
                if self._stop.is_set():
                    break
                lines.append(f"[{fmt_time(seg.start)} → {fmt_time(seg.end)}]  {seg.text.strip()}")

            if not self._stop.is_set():
                self.on_finished("\n".join(lines), info.duration)

        except Exception as e:
            import traceback
            Path("error.log").write_text(traceback.format_exc(), encoding="utf-8")
            self.on_error(str(e))
        finally:
            if tmp_file and os.path.exists(tmp_file):
                os.remove(tmp_file)


async def main(page: ft.Page):
    page.title = "Luminous Transcription"
    page.theme_mode = ft.ThemeMode.LIGHT
    page.padding = 0
    page.bgcolor = C_BG
    page.window.min_width = 900
    page.window.min_height = 620
    page.window.width = 1100
    page.window.height = 760

    settings = load_settings()
    state = {"worker": None, "audio_path": None}

    # ── Pulse dot ────────────────────────────────────────────────────────
    pulse_timer_ref = [None]
    pulse_on = [True]

    pulse_dot = ft.Container(width=8, height=8, border_radius=4, bgcolor="#5da2ff")

    def _pulse_tick():
        pulse_on[0] = not pulse_on[0]
        pulse_dot.bgcolor = "#5da2ff" if pulse_on[0] else C_PRIMARY
        page.update()
        t = threading.Timer(0.65, _pulse_tick)
        t.daemon = True
        pulse_timer_ref[0] = t
        t.start()

    def pulse_start():
        pulse_dot.bgcolor = "#5da2ff"
        t = threading.Timer(0.65, _pulse_tick)
        t.daemon = True
        pulse_timer_ref[0] = t
        t.start()

    def pulse_stop():
        if pulse_timer_ref[0]:
            pulse_timer_ref[0].cancel()
            pulse_timer_ref[0] = None
        pulse_dot.bgcolor = "#4ade80"

    # ── Status labels ────────────────────────────────────────────────────
    status_lbl    = ft.Text("готов", size=11, color=C_ON_SURFACE_VAR)
    stats_lbl     = ft.Text("", size=11, color=C_ON_SURFACE_VAR)
    model_count_lbl = ft.Text("", size=11, color=C_ON_SURFACE_VAR)
    file_name_lbl = ft.Text("—", size=13, color=C_ON_SURFACE, weight=ft.FontWeight.W_500)

    # ── Field helpers ────────────────────────────────────────────────────
    def _text_field(**kw):
        return ft.TextField(
            text_style=ft.TextStyle(color=C_ON_SURFACE, size=13),
            hint_style=ft.TextStyle(color=C_OUTLINE_VAR, size=13),
            bgcolor=C_CONTAINER_HIGHEST,
            border=ft.InputBorder.UNDERLINE,
            border_color=C_OUTLINE_VAR,
            focused_border_color=C_PRIMARY,
            border_radius=ft.BorderRadius(top_left=6, top_right=6, bottom_left=0, bottom_right=0),
            content_padding=ft.Padding(left=10, right=10, top=8, bottom=8),
            cursor_color=C_PRIMARY,
            **kw,
        )

    def _dropdown(**kw):
        return ft.Dropdown(
            text_style=ft.TextStyle(color=C_ON_SURFACE, size=13),
            hint_style=ft.TextStyle(color=C_OUTLINE_VAR, size=13),
            bgcolor=C_CONTAINER_HIGHEST,
            border_color=C_OUTLINE_VAR,
            focused_border_color=C_PRIMARY,
            border_radius=ft.BorderRadius(top_left=6, top_right=6, bottom_left=0, bottom_right=0),
            content_padding=ft.Padding(left=10, right=4, top=0, bottom=0),
            **kw,
        )

    # ── Config controls ───────────────────────────────────────────────────
    models_dir_field = _text_field(
        value=settings.get("models_dir", DEFAULT_MODELS_DIR),
        hint_text="путь к папке моделей",
        width=160,
        height=40,
    )

    model_dd = _dropdown(hint_text="модель", width=140, height=40)

    device_dd = _dropdown(
        value=settings.get("device", _default_device()),
        options=[
            ft.dropdown.Option("cuda", "GPU"),
            ft.dropdown.Option("cpu", "CPU"),
        ],
        width=90,
        height=40,
    )

    lang_map = {
        "auto": "Авто", "ru": "Русский", "en": "English",
        "de": "Deutsch", "fr": "Français", "es": "Español",
        "it": "Italiano", "ja": "日本語", "zh": "中文", "uk": "Українська",
    }
    lang_dd = _dropdown(
        value=settings.get("lang", "auto"),
        options=[ft.dropdown.Option(k, v) for k, v in lang_map.items()],
        width=110,
        height=40,
    )

    beam_field = _text_field(
        value=str(settings.get("beam", 5)),
        keyboard_type=ft.KeyboardType.NUMBER,
        width=52,
        height=40,
    )

    # ── Download dialog ───────────────────────────────────────────────────
    dl_model_dd = ft.Dropdown(
        value="small",
        options=[ft.dropdown.Option(key=m, text=f"{m}  ({sz})") for m, sz in WHISPER_MODELS],
        text_style=ft.TextStyle(color=C_ON_SURFACE, size=13),
        bgcolor=C_CONTAINER_HIGHEST,
        border_color=C_OUTLINE_VAR,
        focused_border_color=C_PRIMARY,
        border_radius=8,
        width=220,
    )
    dl_status_lbl = ft.Text("", size=12, color=C_ON_SURFACE_VAR)
    dl_progress   = ft.ProgressBar(width=320, visible=False, color=C_PRIMARY, bgcolor=C_CONTAINER_HIGH)
    dl_btn_start  = ft.TextButton("Скачать")
    dl_btn_close  = ft.TextButton("Закрыть")

    dl_dialog = ft.AlertDialog(
        modal=True,
        title=ft.Text("Скачать модель Whisper", size=15, weight=ft.FontWeight.W_600),
        content=ft.Column(
            [
                ft.Text("Выберите размер модели:", size=13, color=C_ON_SURFACE_VAR),
                dl_model_dd,
                dl_progress,
                dl_status_lbl,
            ],
            spacing=12,
            tight=True,
            width=340,
        ),
        actions=[dl_btn_start, dl_btn_close],
        actions_alignment=ft.MainAxisAlignment.END,
    )

    def _do_download(model_name: str, dest_dir: str):
        try:
            from huggingface_hub import snapshot_download
            repo_id = f"Systran/faster-whisper-{model_name}"
            local_dir = str(Path(dest_dir) / f"faster-whisper-{model_name}")
            dl_status_lbl.value = f"скачивание {model_name}…"
            dl_progress.visible = True
            dl_btn_start.disabled = True
            page.update()
            snapshot_download(repo_id=repo_id, local_dir=local_dir)
            dl_status_lbl.value = f"✓ {model_name} скачана"
            dl_status_lbl.color = "#16a34a"
            dl_progress.visible = False
            dl_btn_start.disabled = False
            page.update()
            _scan_models()
        except Exception as ex:
            dl_status_lbl.value = f"ошибка: {ex}"
            dl_progress.visible = False
            dl_btn_start.disabled = False
            page.update()

    def _on_dl_start(e):
        dest_dir = models_dir_field.value or DEFAULT_MODELS_DIR
        Path(dest_dir).mkdir(parents=True, exist_ok=True)
        dl_status_lbl.color = C_ON_SURFACE_VAR
        threading.Thread(
            target=_do_download,
            args=(dl_model_dd.value, dest_dir),
            daemon=True,
        ).start()

    def _on_dl_close(e):
        if not dl_btn_start.disabled:
            dl_dialog.open = False
            page.update()

    dl_btn_start.on_click = _on_dl_start
    dl_btn_close.on_click = _on_dl_close

    def _open_dl_dialog(e):
        dl_status_lbl.value = ""
        dl_status_lbl.color = C_ON_SURFACE_VAR
        dl_progress.visible = False
        dl_btn_start.disabled = False
        dl_dialog.open = True
        page.update()

    # ── Drop zone ─────────────────────────────────────────────────────────
    drop_icon_ctrl = ft.Icon(ft.Icons.UPLOAD_FILE_OUTLINED, size=36, color=C_PRIMARY)
    drop_title     = ft.Text("Перетащите файлы сюда", size=17,
                             weight=ft.FontWeight.W_600, color=C_ON_SURFACE)
    drop_sub       = ft.Text("Поддерживаются форматы MP3, WAV, MP4, MKV",
                             size=12, color=C_ON_SURFACE_VAR)

    pick_file_btn = ft.OutlinedButton(
        "Выбрать файл",
        style=ft.ButtonStyle(
            color={CS.DEFAULT: C_PRIMARY, CS.HOVERED: C_PRIMARY_DIM},
            side={CS.DEFAULT: ft.BorderSide(1, C_PRIMARY)},
            shape=ft.RoundedRectangleBorder(radius=8),
            padding=ft.Padding(left=20, right=20, top=10, bottom=10),
        ),
    )

    drop_zone = ft.Container(
        content=ft.Column(
            [
                ft.Container(
                    content=drop_icon_ctrl,
                    width=68, height=68,
                    border_radius=34,
                    bgcolor="#005fb214",
                    alignment=ft.Alignment(0, 0),
                ),
                drop_title,
                drop_sub,
                pick_file_btn,
            ],
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            alignment=ft.MainAxisAlignment.CENTER,
            spacing=10,
        ),
        border_radius=16,
        bgcolor=C_CONTAINER_LOW,
        border=ft.Border.all(1, "#d0d4d4"),
        expand=True,
        ink=True,
        ink_color=C_CONTAINER_HIGH,
    )

    def set_audio(path: str):
        state["audio_path"] = path
        name = Path(path).name
        drop_icon_ctrl.name = ft.Icons.AUDIO_FILE_OUTLINED
        drop_title.value = name
        drop_sub.value = "нажмите чтобы сменить файл"
        drop_zone.bgcolor = "#eef4fc"
        drop_zone.border = ft.Border.all(1, C_PRIMARY)
        file_name_lbl.value = name
        _set_status("файл выбран")
        _update_run_btn()
        page.update()

    # ── Run / Stop buttons ────────────────────────────────────────────────
    run_btn_text = ft.Text(
        "Транскрибировать", size=14, weight=ft.FontWeight.W_700, color=C_ON_PRIMARY
    )
    run_btn_container = ft.Container(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.PLAY_ARROW, color=C_ON_PRIMARY, size=18),
                run_btn_text,
            ],
            spacing=8,
            alignment=ft.MainAxisAlignment.CENTER,
        ),
        gradient=ft.LinearGradient(
            begin=ft.Alignment(-1, -1),
            end=ft.Alignment(1, 1),
            colors=[C_PRIMARY, C_PRIMARY_DIM],
        ),
        border_radius=8,
        padding=ft.Padding(left=24, right=24, top=14, bottom=14),
        expand=True,
        ink=True,
        ink_color="#ffffff22",
        opacity=0.45,
    )

    stop_btn_container = ft.Container(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.STOP, color=C_SECONDARY, size=18),
                ft.Text("Стоп", size=14, weight=ft.FontWeight.W_700, color=C_SECONDARY),
            ],
            spacing=8,
            alignment=ft.MainAxisAlignment.CENTER,
        ),
        bgcolor=C_CONTAINER_HIGHEST,
        border_radius=8,
        padding=ft.Padding(left=24, right=24, top=14, bottom=14),
        ink=True,
        ink_color=C_CONTAINER_HIGH,
        opacity=0.45,
    )

    # ── Output area ───────────────────────────────────────────────────────
    output_field = ft.TextField(
        multiline=True,
        read_only=True,
        expand=True,
        min_lines=10,
        hint_text="результат транскрипции появится здесь\n\n[мм:сс → мм:сс]  текст сегмента",
        hint_style=ft.TextStyle(color=C_OUTLINE_VAR, size=13),
        text_style=ft.TextStyle(color=C_ON_SURFACE, size=14, height=1.75),
        bgcolor=C_WHITE,
        border=ft.InputBorder.NONE,
        content_padding=ft.Padding(left=32, right=32, top=24, bottom=24),
        cursor_color=C_PRIMARY,
    )

    copy_btn = ft.IconButton(
        icon=ft.Icons.CONTENT_COPY_OUTLINED,
        icon_color=C_SECONDARY,
        icon_size=18,
        tooltip="Копировать",
        disabled=True,
        on_click=lambda _: _on_copy(),
    )
    save_btn = ft.IconButton(
        icon=ft.Icons.DOWNLOAD_OUTLINED,
        icon_color=C_SECONDARY,
        icon_size=18,
        tooltip="Сохранить .txt",
        disabled=True,
    )

    # ── File pickers ──────────────────────────────────────────────────────
    file_picker = ft.FilePicker()
    dir_picker  = ft.FilePicker()
    save_picker = ft.FilePicker()
    page.services.append(file_picker)
    page.services.append(dir_picker)
    page.services.append(save_picker)

    async def _pick_file(e):
        files = await file_picker.pick_files(allow_multiple=False)
        if files:
            set_audio(files[0].path)

    async def _pick_dir(e):
        init_dir = models_dir_field.value
        if init_dir and not Path(init_dir).exists():
            init_dir = str(Path.home())
        path = await dir_picker.get_directory_path(initial_directory=init_dir)
        if path:
            models_dir_field.value = path
            page.update()
            _scan_models()

    async def _on_save(e):
        name = (Path(state["audio_path"]).stem + "_transcription.txt"
                if state["audio_path"] else "transcription.txt")
        path = await save_picker.save_file(file_name=name, allowed_extensions=["txt"])
        if path:
            p = path if path.endswith(".txt") else path + ".txt"
            Path(p).write_text(output_field.value or "", encoding="utf-8")
            _set_status(f"сохранено: {Path(p).name}")

    drop_zone.on_click    = _pick_file
    pick_file_btn.on_click = _pick_file
    save_btn.on_click     = _on_save

    # ── Logic ─────────────────────────────────────────────────────────────
    def _set_status(text: str, color: str = C_ON_SURFACE_VAR):
        status_lbl.value = text
        status_lbl.color = color
        page.update()

    def _update_run_btn():
        enabled = (
            model_dd.value is not None
            and state["audio_path"] is not None
            and state["worker"] is None
        )
        run_btn_container.opacity = 1.0 if enabled else 0.45
        run_btn_container.on_click = (lambda _: _on_run()) if enabled else None
        busy = state["worker"] is not None
        stop_btn_container.opacity = 1.0 if busy else 0.45
        stop_btn_container.on_click = (lambda _: _on_stop()) if busy else None

    def _scan_models():
        found = scan_models(models_dir_field.value or DEFAULT_MODELS_DIR)
        model_dd.options = [ft.dropdown.Option(key=p, text=n) for n, p in found]
        if found:
            paths = [p for _, p in found]
            if model_dd.value not in paths:
                model_dd.value = found[0][1]
            cnt = len(found)
            model_count_lbl.value = f"{cnt} {'модель' if cnt == 1 else 'моделей'}"
        else:
            model_dd.value = None
            model_count_lbl.value = "моделей нет"
        _update_run_btn()
        page.update()

    def _on_run():
        if not model_dd.value or not state["audio_path"]:
            return
        save_settings({
            "models_dir": models_dir_field.value,
            "device": device_dd.value,
            "lang": lang_dd.value,
            "beam": beam_field.value,
        })
        output_field.value = ""
        stats_lbl.value = ""
        copy_btn.disabled = True
        save_btn.disabled = True
        pulse_start()
        _set_status("запуск...", C_PRIMARY)

        w = TranscribeWorker(
            model_path=model_dd.value,
            audio_path=state["audio_path"],
            language=lang_dd.value or "auto",
            beam_size=beam_field.value or "5",
            device=device_dd.value or "cpu",
            on_progress=lambda msg: _set_status(msg, C_PRIMARY),
            on_finished=_on_finished,
            on_error=_on_error,
        )
        state["worker"] = w
        _update_run_btn()
        w.start()

    def _on_stop():
        if state["worker"]:
            state["worker"].stop()
            state["worker"] = None
        _reset_ui()
        _set_status("остановлено", "#f59e0b")

    def _on_finished(text: str, duration: float):
        output_field.value = text
        lines = [l for l in text.splitlines() if l.strip()]
        stats_lbl.value = f"{fmt_time(duration)}  ·  {len(lines)} сегм."
        copy_btn.disabled = False
        save_btn.disabled = False
        state["worker"] = None
        _reset_ui()
        _set_status("готово ✓", "#16a34a")

    def _on_error(msg: str):
        output_field.value = f"ошибка:\n{msg}\n\nподробности в error.log"
        state["worker"] = None
        _reset_ui()
        _set_status("ошибка", "#dc2626")

    def _reset_ui():
        pulse_stop()
        _update_run_btn()
        page.update()

    def _on_copy():
        if output_field.value:
            page.set_clipboard(output_field.value)
            old_v, old_c = status_lbl.value, status_lbl.color
            _set_status("скопировано ✓", "#16a34a")
            def _restore():
                import time; time.sleep(2)
                _set_status(old_v, old_c)
            threading.Thread(target=_restore, daemon=True).start()

    # ── UI Assembly ────────────────────────────────────────────────────────

    def _icon_btn(icon, tooltip=""):
        return ft.IconButton(
            icon=icon,
            icon_color=C_SECONDARY,
            icon_size=20,
            tooltip=tooltip,
            style=ft.ButtonStyle(
                shape=ft.RoundedRectangleBorder(radius=8),
                overlay_color={CS.HOVERED: C_CONTAINER_LOW},
            ),
        )

    def _labeled(label, *controls):
        return ft.Column(
            [
                ft.Text(label.upper(), size=10, color=C_ON_SURFACE_VAR,
                        weight=ft.FontWeight.W_500,
                        style=ft.TextStyle(letter_spacing=0.8)),
                ft.Row(list(controls), spacing=6,
                       vertical_alignment=ft.CrossAxisAlignment.CENTER),
            ],
            spacing=4,
        )

    def _vdivider():
        return ft.Container(
            width=1, height=42, bgcolor="#d0d4d4",
            margin=ft.Margin(left=4, right=4, top=0, bottom=0),
        )

    def _info_row(icon, label, value_ctrl):
        return ft.Row(
            [
                ft.Icon(icon, color=C_SECONDARY, size=20),
                ft.Column(
                    [ft.Text(label, size=10, color=C_ON_SURFACE_VAR), value_ctrl],
                    spacing=1,
                ),
            ],
            spacing=14,
            vertical_alignment=ft.CrossAxisAlignment.START,
        )

    # ── Header ────────────────────────────────────────────────────────────
    header = ft.Container(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.GRAPHIC_EQ, color=C_PRIMARY, size=22),
                ft.Container(expand=True),
                ft.Row(
                    [
                        _icon_btn(ft.Icons.SETTINGS_OUTLINED, "Настройки"),
                        _icon_btn(ft.Icons.HELP_OUTLINE, "Помощь"),
                        _icon_btn(ft.Icons.ACCOUNT_CIRCLE_OUTLINED, "Профиль"),
                    ],
                    spacing=2,
                ),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=C_WHITE,
        padding=ft.Padding(left=24, right=16, top=0, bottom=0),
        height=52,
        border=ft.Border(bottom=ft.BorderSide(1, "#e8eaea")),
        shadow=ft.BoxShadow(blur_radius=8, color="#0000000a", offset=ft.Offset(0, 2)),
    )

    # ── Config bar ────────────────────────────────────────────────────────
    folder_btn = ft.IconButton(
        icon=ft.Icons.FOLDER_OPEN_OUTLINED,
        icon_color=C_PRIMARY,
        icon_size=20,
        tooltip="Выбрать папку",
        style=ft.ButtonStyle(
            bgcolor={CS.DEFAULT: C_CONTAINER_HIGHEST, CS.HOVERED: C_CONTAINER_HIGH},
            shape=ft.RoundedRectangleBorder(radius=6),
        ),
        on_click=_pick_dir,
    )
    refresh_btn = ft.IconButton(
        icon=ft.Icons.REFRESH,
        icon_color=C_SECONDARY,
        icon_size=18,
        tooltip="Обновить список моделей",
        style=ft.ButtonStyle(
            bgcolor={CS.DEFAULT: C_CONTAINER_HIGHEST, CS.HOVERED: C_CONTAINER_HIGH},
            shape=ft.RoundedRectangleBorder(radius=6),
        ),
        on_click=lambda _: _scan_models(),
    )
    download_model_btn = ft.OutlinedButton(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.DOWNLOAD_OUTLINED, size=14, color=C_PRIMARY),
                ft.Text("Скачать", size=12, color=C_PRIMARY),
            ],
            spacing=3,
        ),
        style=ft.ButtonStyle(
            side={CS.DEFAULT: ft.BorderSide(1, C_PRIMARY)},
            shape=ft.RoundedRectangleBorder(radius=6),
            padding=ft.Padding(left=8, right=8, top=6, bottom=6),
            overlay_color={CS.HOVERED: "#005fb20d"},
        ),
        on_click=_open_dl_dialog,
    )

    config_bar = ft.Container(
        content=ft.ResponsiveRow(
            [
                ft.Column(
                    [_labeled("Путь к модели", models_dir_field, folder_btn, refresh_btn)],
                    col={"xs": 12, "sm": 12, "md": 4, "lg": 3},
                ),
                ft.Column(
                    [_labeled("Модель", model_dd, download_model_btn)],
                    col={"xs": 12, "sm": 6, "md": 4, "lg": 3},
                ),
                ft.Column(
                    [_labeled("Устройство", device_dd)],
                    col={"xs": 6, "sm": 3, "md": 2, "lg": 2},
                ),
                ft.Column(
                    [_labeled("Язык", lang_dd)],
                    col={"xs": 6, "sm": 3, "md": 2, "lg": 2},
                ),
                ft.Column(
                    [_labeled("Beam", beam_field)],
                    col={"xs": 4, "sm": 2, "md": 1, "lg": 1},
                ),
                ft.Column(
                    [ft.Container(height=20), model_count_lbl],
                    col={"xs": 8, "sm": 4, "md": 3, "lg": 1},
                ),
            ],
            spacing=12,
            run_spacing=8,
        ),
        bgcolor=C_CONTAINER,
        padding=ft.Padding(left=24, right=24, top=12, bottom=12),
        border=ft.Border(bottom=ft.BorderSide(1, "#d8dbdb")),
    )

    # ── File info card ────────────────────────────────────────────────────
    file_info_card = ft.Container(
        content=ft.Column(
            [
                ft.Text("ИНФОРМАЦИЯ О ФАЙЛЕ", size=10, color=C_ON_SURFACE_VAR,
                        weight=ft.FontWeight.W_600,
                        style=ft.TextStyle(letter_spacing=1.2)),
                ft.Container(height=4),
                _info_row(ft.Icons.DESCRIPTION_OUTLINED, "Имя файла", file_name_lbl),
                _info_row(ft.Icons.SCHEDULE_OUTLINED, "Статус", status_lbl),
                ft.Container(expand=True),
                ft.Divider(height=1, color="#ebebeb"),
                ft.Row(
                    [
                        ft.Text("Статус системы", size=11, color=C_ON_SURFACE_VAR),
                        ft.Row(
                            [
                                pulse_dot,
                                ft.Text("Готов", size=11, color=C_PRIMARY,
                                        weight=ft.FontWeight.W_500),
                            ],
                            spacing=6,
                        ),
                    ],
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
            ],
            spacing=14,
            expand=True,
        ),
        bgcolor=C_WHITE,
        border_radius=12,
        padding=24,
        expand=True,
        shadow=ft.BoxShadow(
            blur_radius=20,
            color="#0000000f",
            offset=ft.Offset(0, 4),
        ),
    )

    # ── Middle section (drop zone + file info) ────────────────────────────
    middle_section = ft.Container(
        content=ft.Row(
            [
                ft.Column(
                    [
                        drop_zone,
                        ft.Row([run_btn_container, stop_btn_container], spacing=12),
                    ],
                    spacing=14,
                    expand=2,
                ),
                ft.Column(
                    [file_info_card],
                    expand=1,
                ),
            ],
            spacing=20,
            vertical_alignment=ft.CrossAxisAlignment.STRETCH,
        ),
        padding=ft.Padding(left=24, right=24, top=20, bottom=0),
        expand=1,
    )

    # ── Transcription section ─────────────────────────────────────────────
    output_section = ft.Container(
        content=ft.Column(
            [
                ft.Container(
                    content=ft.Row(
                        [
                            ft.Text("Результат транскрипции", size=14,
                                    weight=ft.FontWeight.W_700, color=C_ON_SURFACE),
                            ft.Row([copy_btn, save_btn], spacing=0),
                        ],
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    bgcolor=C_CONTAINER_LOW,
                    padding=ft.Padding(left=24, right=12, top=10, bottom=10),
                    border=ft.Border(bottom=ft.BorderSide(1, "#ebebeb")),
                ),
                output_field,
            ],
            spacing=0,
            expand=True,
        ),
        bgcolor=C_WHITE,
        border_radius=ft.BorderRadius(top_left=12, top_right=12, bottom_left=0, bottom_right=0),
        margin=ft.Margin(left=24, right=24, top=16, bottom=0),
        expand=2,
        shadow=ft.BoxShadow(
            blur_radius=20,
            color="#0000000f",
            offset=ft.Offset(0, -2),
        ),
        clip_behavior=ft.ClipBehavior.ANTI_ALIAS,
    )

    # ── Footer ────────────────────────────────────────────────────────────
    footer = ft.Container(
        content=ft.Row(
            [
                ft.Row(
                    [
                        ft.Icon(ft.Icons.BOLT, size=14, color=C_ON_SURFACE_VAR),
                        stats_lbl,
                    ],
                    spacing=6,
                ),
                ft.Text("Версия 2.0 · Luminous", size=11, color=C_OUTLINE_VAR),
            ],
            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=C_CONTAINER_LOW,
        padding=ft.Padding(left=24, right=24, top=0, bottom=0),
        height=32,
        border=ft.Border(top=ft.BorderSide(1, "#e4e7e7")),
    )

    # ── Register dialog & build page ──────────────────────────────────────
    page.overlay.append(dl_dialog)

    page.add(
        ft.Column(
            [
                header,
                config_bar,
                middle_section,
                output_section,
                footer,
            ],
            spacing=0,
            expand=True,
        )
    )

    _scan_models()


ft.run(main)
