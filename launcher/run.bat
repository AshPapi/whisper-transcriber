@echo off
title Whisper Transcriber
cd /d "%~dp0"

echo Starting Whisper Transcriber...
echo.

REM ── Start Python backend ──────────────────────────────────────────────────
echo [1/2] Starting Python backend on port 8765...
start "WhisperBackend" /min cmd /c "cd /d "%~dp0..\python_backend" && uvicorn server:app --host 127.0.0.1 --port 8765 2>&1 | tee backend.log"

REM Wait for backend to start
timeout /t 3 /nobreak >nul

REM ── Start Flutter app ─────────────────────────────────────────────────────
echo [2/2] Launching Flutter app...
cd /d "%~dp0..\flutter_ui"

if exist "build\windows\x64\runner\Release\whisper_transcriber.exe" (
    start "" "build\windows\x64\runner\Release\whisper_transcriber.exe"
) else if exist "build\windows\runner\Release\whisper_transcriber.exe" (
    start "" "build\windows\runner\Release\whisper_transcriber.exe"
) else (
    echo Flutter app not built yet. Running in debug mode...
    flutter run -d windows
)
