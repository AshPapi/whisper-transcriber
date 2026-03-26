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

# Если ffmpeg нет в PATH — static-ffmpeg добавит его автоматически
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

# Палитра
C_BG       = "#f1f5f9"
C_HEADER   = "#0f172a"
C_WHITE    = "#ffffff"
C_TEXT     = "#0f172a"
C_MUTED    = "#64748b"
C_LIGHT    = "#94a3b8"
C_BORDER   = "#e2e8f0"
C_INPUT    = "#f1f5f9"
C_PRIMARY  = "#3b82f6"
C_PRI2     = "#2563eb"
C_PRI3     = "#1d4ed8"
C_DANGER   = "#fef2f2"
C_DANGER_T = "#dc2626"
C_DROP_BG  = "#eff6ff"
C_DROP_BD  = "#93c5fd"
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
    page.title = "Whisper Transcriber"
    page.theme_mode = ft.ThemeMode.LIGHT
    page.padding = 0
    page.bgcolor = C_BG
    page.window.min_width = 760
    page.window.min_height = 580
    page.window.width = 960
    page.window.height = 720

    settings = load_settings()
    state = {"worker": None, "audio_path": None}

    # ── Пульсирующая точка ────────────────────────────────────────────────
    pulse_timer_ref = [None]
    pulse_on = [True]

    pulse_dot = ft.Text("●", size=10, color="#475569")

    def _pulse_tick():
        pulse_on[0] = not pulse_on[0]
        pulse_dot.color = "#60a5fa" if pulse_on[0] else "#3b82f6"
        page.update()
        t = threading.Timer(0.65, _pulse_tick)
        t.daemon = True
        pulse_timer_ref[0] = t
        t.start()

    def pulse_start():
        pulse_dot.color = "#60a5fa"
        t = threading.Timer(0.65, _pulse_tick)
        t.daemon = True
        pulse_timer_ref[0] = t
        t.start()

    def pulse_stop():
        if pulse_timer_ref[0]:
            pulse_timer_ref[0].cancel()
            pulse_timer_ref[0] = None
        pulse_dot.color = "#475569"

    # ── Контролы ──────────────────────────────────────────────────────────
    status_lbl      = ft.Text("готов", size=12, color="#94a3b8")
    stats_lbl       = ft.Text("", size=12, color="#94a3b8")
    model_count_lbl = ft.Text("", size=12, color=C_MUTED)

    # ── Диалог скачивания модели ───────────────────────────────────────────
    dl_model_dd = ft.Dropdown(
        value="small",
        options=[ft.dropdown.Option(key=m, text=f"{m}  ({sz})") for m, sz in WHISPER_MODELS],
        text_style=ft.TextStyle(color=C_TEXT, size=13),
        bgcolor=C_INPUT,
        border_color="transparent",
        focused_border_color=C_PRIMARY,
        border_radius=8,
        width=220,
    )
    dl_status_lbl = ft.Text("", size=12, color=C_MUTED)
    dl_progress = ft.ProgressBar(width=320, visible=False, color=C_PRIMARY, bgcolor=C_BORDER)
    dl_btn_start = ft.TextButton("Скачать")
    dl_btn_close = ft.TextButton("Закрыть")

    dl_dialog = ft.AlertDialog(
        modal=True,
        title=ft.Text("Скачать модель Whisper", size=15, weight=ft.FontWeight.W_600),
        content=ft.Column(
            [
                ft.Text("Выберите размер модели:", size=13, color=C_MUTED),
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
            page.run_thread(lambda: _dl_set_status(f"скачивание {model_name}…", indeterminate=True))
            snapshot_download(repo_id=repo_id, local_dir=local_dir)
            page.run_thread(lambda: _dl_done(model_name))
        except Exception as ex:
            page.run_thread(lambda: _dl_set_status(f"ошибка: {ex}", indeterminate=False))

    def _dl_set_status(text: str, indeterminate: bool):
        dl_status_lbl.value = text
        dl_progress.visible = indeterminate
        dl_btn_start.disabled = indeterminate
        page.update()

    def _dl_done(model_name: str):
        dl_status_lbl.value = f"✓ {model_name} скачана"
        dl_status_lbl.color = "#4ade80"
        dl_progress.visible = False
        dl_btn_start.disabled = False
        page.update()
        _scan_models()

    def _on_dl_start(e):
        model_name = dl_model_dd.value
        dest_dir = models_dir_field.value or DEFAULT_MODELS_DIR
        Path(dest_dir).mkdir(parents=True, exist_ok=True)
        dl_status_lbl.color = C_MUTED
        threading.Thread(target=_do_download, args=(model_name, dest_dir), daemon=True).start()

    def _on_dl_close(e):
        if not dl_btn_start.disabled:
            dl_dialog.open = False
            page.update()

    dl_btn_start.on_click = _on_dl_start
    dl_btn_close.on_click = _on_dl_close

    def _open_dl_dialog(e):
        dl_status_lbl.value = ""
        dl_status_lbl.color = C_MUTED
        dl_progress.visible = False
        dl_btn_start.disabled = False
        dl_dialog.open = True
        page.update()

    download_model_btn = ft.TextButton(
        "↓ Скачать модель",
        style=ft.ButtonStyle(
            color={CS.DEFAULT: C_PRIMARY, CS.HOVERED: C_PRI2},
        ),
        on_click=_open_dl_dialog,
    )

    progress_bar = ft.ProgressBar(
        width=80, height=3,
        color="#60a5fa", bgcolor="#334155",
        visible=False,
    )

    output_field = ft.TextField(
        multiline=True,
        read_only=True,
        expand=True,
        min_lines=14,
        hint_text="результат транскрибации появится здесь\n\n[мм:сс → мм:сс]  текст",
        hint_style=ft.TextStyle(color=C_LIGHT, size=13),
        text_style=ft.TextStyle(color=C_TEXT, size=14, height=1.7),
        bgcolor=C_WHITE,
        border=ft.InputBorder.NONE,
        border_radius=12,
        content_padding=ft.Padding(left=28, right=28, top=24, bottom=24),
        cursor_color=C_PRIMARY,
    )

    # ── Настройки ─────────────────────────────────────────────────────────
    input_pad = ft.Padding(left=10, right=10, top=5, bottom=5)
    dd_pad    = ft.Padding(left=10, right=10, top=0, bottom=0)

    models_dir_field = ft.TextField(
        value=settings.get("models_dir", DEFAULT_MODELS_DIR),
        hint_text="папка моделей",
        hint_style=ft.TextStyle(color=C_LIGHT, size=12),
        text_style=ft.TextStyle(color=C_TEXT, size=12),
        bgcolor=C_INPUT,
        border=ft.InputBorder.NONE,
        focused_border_color=C_PRIMARY,
        border_radius=8,
        content_padding=input_pad,
        height=34,
        width=180,
        cursor_color=C_PRIMARY,
    )

    model_dd = ft.Dropdown(
        hint_text="модель",
        text_style=ft.TextStyle(color=C_TEXT, size=12),
        hint_style=ft.TextStyle(color=C_LIGHT, size=12),
        bgcolor=C_INPUT,
        border_color="transparent",
        focused_border_color=C_PRIMARY,
        border_radius=8,
        content_padding=dd_pad,
        width=140,
        height=34,
    )

    device_dd = ft.Dropdown(
        value=settings.get("device", "cuda"),
        options=[ft.dropdown.Option("cuda"), ft.dropdown.Option("cpu")],
        text_style=ft.TextStyle(color=C_TEXT, size=12),
        bgcolor=C_INPUT,
        border_color="transparent",
        focused_border_color=C_PRIMARY,
        border_radius=8,
        content_padding=dd_pad,
        width=100,
        height=34,
    )

    lang_dd = ft.Dropdown(
        value=settings.get("lang", "auto"),
        options=[ft.dropdown.Option(l) for l in
                 ["auto", "ru", "en", "de", "fr", "es", "it", "ja", "zh", "uk"]],
        text_style=ft.TextStyle(color=C_TEXT, size=12),
        bgcolor=C_INPUT,
        border_color="transparent",
        focused_border_color=C_PRIMARY,
        border_radius=8,
        content_padding=dd_pad,
        width=115,
        height=34,
    )

    beam_field = ft.TextField(
        value=str(settings.get("beam", 5)),
        keyboard_type=ft.KeyboardType.NUMBER,
        text_style=ft.TextStyle(color=C_TEXT, size=12),
        bgcolor=C_INPUT,
        border=ft.InputBorder.NONE,
        focused_border_color=C_PRIMARY,
        border_radius=8,
        content_padding=input_pad,
        height=34,
        width=44,
        cursor_color=C_PRIMARY,
    )

    # ── Drop zone ─────────────────────────────────────────────────────────
    drop_icon  = ft.Text("↑", size=26, color=C_DROP_BD)
    drop_title = ft.Text("ПЕРЕТАЩИТЕ ФАЙЛ СЮДА", size=12,
                         weight=ft.FontWeight.W_700, color=C_MUTED)
    drop_sub   = ft.Text("или нажмите для выбора · аудио и видео",
                         size=11, color=C_LIGHT)

    drop_zone = ft.Container(
        content=ft.Column(
            [drop_icon, drop_title, drop_sub],
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            alignment=ft.MainAxisAlignment.CENTER,
            spacing=6,
        ),
        height=120,
        border_radius=12,
        bgcolor=C_DROP_BG,
        border=ft.Border.all(2, C_DROP_BD),
    )

    def _drop_hover(e):
        if e.data == "true":
            drop_zone.bgcolor = "#dbeafe"
            drop_zone.border = ft.Border.all(2, "#60a5fa")
        else:
            drop_zone.bgcolor = C_DROP_BG
            drop_zone.border = ft.Border.all(2, C_DROP_BD)
        page.update()

    drop_zone.on_hover = _drop_hover

    def set_audio(path: str):
        state["audio_path"] = path
        name = Path(path).name
        drop_icon.value = "♪"
        drop_icon.color = C_PRIMARY
        drop_title.value = name
        drop_title.color = C_TEXT
        drop_sub.value = "нажмите чтобы сменить"
        drop_sub.color = C_MUTED
        drop_zone.bgcolor = "#dbeafe"
        drop_zone.border = ft.Border.all(2, C_PRIMARY)
        _set_status(f"файл: {name}")
        _update_run_btn()
        page.update()

    # ── Кнопки ────────────────────────────────────────────────────────────
    ghost_style = ft.ButtonStyle(
        color={CS.DEFAULT: C_MUTED, CS.HOVERED: C_TEXT, CS.DISABLED: "#cbd5e1"},
        bgcolor={CS.HOVERED: "#e2e8f0"},
        shape=ft.RoundedRectangleBorder(radius=8),
        padding=ft.Padding(left=14, right=14, top=8, bottom=8),
    )

    tb_style = ft.ButtonStyle(
        color={CS.DEFAULT: C_MUTED, CS.HOVERED: C_TEXT},
        bgcolor={CS.HOVERED: "#e2e8f0"},
        shape=ft.RoundedRectangleBorder(radius=8),
        padding=ft.Padding(left=10, right=10, top=5, bottom=5),
    )

    run_btn = ft.Button(
        content="Транскрибировать",
        disabled=True,
        style=ft.ButtonStyle(
            bgcolor={CS.DEFAULT: C_PRIMARY, CS.HOVERED: C_PRI2,
                     CS.DISABLED: "#93c5fd", CS.PRESSED: C_PRI3},
            color={CS.DEFAULT: "#ffffff", CS.DISABLED: "#dbeafe"},
            shape=ft.RoundedRectangleBorder(radius=8),
            padding=ft.Padding(left=24, right=24, top=10, bottom=10),
        ),
        on_click=lambda _: _on_run(),
    )

    stop_btn = ft.Button(
        content="Стоп",
        disabled=True,
        style=ft.ButtonStyle(
            bgcolor={CS.DEFAULT: C_DANGER, CS.HOVERED: "#fee2e2",
                     CS.DISABLED: "#fff5f5"},
            color={CS.DEFAULT: C_DANGER_T, CS.HOVERED: "#b91c1c",
                   CS.DISABLED: "#fca5a5"},
            shape=ft.RoundedRectangleBorder(radius=8),
            padding=ft.Padding(left=18, right=18, top=10, bottom=10),
        ),
        on_click=lambda _: _on_stop(),
    )

    copy_btn = ft.Button(content="Копировать", disabled=True,
                         style=ghost_style, on_click=lambda _: _on_copy())
    save_btn = ft.Button(content="Сохранить .txt", disabled=True,
                         style=ghost_style)

    # ── File pickers (async API) ──────────────────────────────────────────
    file_picker = ft.FilePicker()
    dir_picker  = ft.FilePicker()
    save_picker = ft.FilePicker()
    page.services.extend([file_picker, dir_picker, save_picker])

    async def _pick_file(e):
        files = await file_picker.pick_files(allow_multiple=False)
        if files:
            set_audio(files[0].path)

    async def _pick_dir(e):
        init_dir = models_dir_field.value
        if init_dir and not Path(init_dir).exists():
            init_dir = str(Path.home())
        path = await dir_picker.get_directory_path(
            initial_directory=init_dir
        )
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
            _set_status(f"сохранено: {Path(p).name}", "#4ade80")

    drop_zone.on_click = _pick_file
    save_btn.on_click  = _on_save

    # ── Логика ────────────────────────────────────────────────────────────
    def _set_status(text: str, color: str = "#94a3b8"):
        status_lbl.value = text
        status_lbl.color = color
        page.update()

    def _update_run_btn():
        run_btn.disabled = not (
            model_dd.value is not None
            and state["audio_path"] is not None
            and state["worker"] is None
        )

    def _scan_models():
        found = scan_models(models_dir_field.value or DEFAULT_MODELS_DIR)
        model_dd.options = [ft.dropdown.Option(key=path, text=name) for name, path in found]
        if found:
            paths = [p for _, p in found]
            if model_dd.value not in paths:
                model_dd.value = found[0][1]
            model_count_lbl.value = f"{len(found)} {'модель' if len(found)==1 else 'моделей'}"
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
        progress_bar.visible = True
        run_btn.disabled = True
        stop_btn.disabled = False
        copy_btn.disabled = True
        save_btn.disabled = True
        pulse_start()
        _set_status("запуск...", "#60a5fa")

        w = TranscribeWorker(
            model_path=model_dd.value,
            audio_path=state["audio_path"],
            language=lang_dd.value or "auto",
            beam_size=beam_field.value or "5",
            device=device_dd.value or "cpu",
            on_progress=lambda msg: _set_status(msg, "#60a5fa"),
            on_finished=_on_finished,
            on_error=_on_error,
        )
        state["worker"] = w
        w.start()

    def _on_stop():
        if state["worker"]:
            state["worker"].stop()
            state["worker"] = None
        _reset_ui()
        _set_status("остановлено", "#fbbf24")

    def _on_finished(text: str, duration: float):
        output_field.value = text
        lines = [l for l in text.splitlines() if l.strip()]
        stats_lbl.value = f"{fmt_time(duration)}  ·  {len(lines)} сегм."
        copy_btn.disabled = False
        save_btn.disabled = False
        state["worker"] = None
        _reset_ui()
        _set_status("готово", "#4ade80")

    def _on_error(msg: str):
        output_field.value = f"ошибка:\n{msg}\n\nподробности в error.log"
        state["worker"] = None
        _reset_ui()
        _set_status(f"ошибка: {msg}", "#f87171")

    def _reset_ui():
        progress_bar.visible = False
        stop_btn.disabled = True
        pulse_stop()
        _update_run_btn()
        page.update()

    def _on_copy():
        if output_field.value:
            page.set_clipboard(output_field.value)
            old_v, old_c = status_lbl.value, status_lbl.color
            _set_status("скопировано", "#4ade80")
            def _restore():
                import time; time.sleep(2)
                _set_status(old_v, old_c)
            threading.Thread(target=_restore, daemon=True).start()

    # ── Сборка UI ─────────────────────────────────────────────────────────
    def _divider():
        return ft.Container(width=1, height=44, bgcolor=C_BORDER,
                            margin=ft.Margin(left=4, right=4, top=0, bottom=0))

    def _labeled(label: str, *controls):
        return ft.Column(
            [
                ft.Text(label, size=10, color=C_LIGHT, weight=ft.FontWeight.W_500),
                ft.Row(list(controls), spacing=4,
                       vertical_alignment=ft.CrossAxisAlignment.CENTER),
            ],
            spacing=3,
            horizontal_alignment=ft.CrossAxisAlignment.START,
        )

    title_bar = ft.Container(
        content=ft.Row(
            [
                ft.Text("Whisper Transcriber", size=16,
                         weight=ft.FontWeight.W_700, color="#ffffff"),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=C_HEADER,
        padding=ft.Padding(left=24, right=24, top=0, bottom=0),
        height=44,
    )

    settings_bar = ft.Container(
        content=ft.Row(
            [
                _labeled(
                    "путь к модели",
                    models_dir_field,
                    ft.Button(content="···", style=tb_style, on_click=_pick_dir),
                    ft.Button(content="↺", style=tb_style, on_click=lambda _: _scan_models()),
                ),
                _divider(),
                _labeled("модель", model_dd),
                _labeled("устройство", device_dd),
                _labeled("язык", lang_dd),
                _divider(),
                _labeled("beam", beam_field),
                _divider(),
                model_count_lbl,
                download_model_btn,
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
            spacing=12,
        ),
        bgcolor=C_WHITE,
        padding=ft.Padding(left=24, right=24, top=8, bottom=8),
        height=70,
        border=ft.Border.only(bottom=ft.BorderSide(1, C_BORDER)),
    )

    action_row = ft.Row(
        [run_btn, stop_btn, ft.Container(expand=True), copy_btn, save_btn],
        spacing=8,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )

    content_area = ft.Container(
        content=ft.Column([drop_zone, action_row], spacing=14),
        padding=ft.Padding(left=20, right=20, top=16, bottom=8),
        bgcolor=C_BG,
    )

    output_container = ft.Container(
        content=output_field,
        expand=True,
        margin=ft.Margin(left=20, right=20, top=0, bottom=12),
    )

    statusbar = ft.Container(
        content=ft.Row(
            [pulse_dot, status_lbl, progress_bar,
             ft.Container(expand=True), stats_lbl],
            spacing=8,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=C_HEADER,
        padding=ft.Padding(left=24, right=24, top=0, bottom=0),
        height=36,
    )

    page.overlay.append(dl_dialog)

    page.add(
        ft.Column(
            [
                title_bar,
                settings_bar,
                content_area,
                output_container,
                statusbar,
            ],
            spacing=0,
            expand=True,
        )
    )

    _scan_models()


ft.run(main)
