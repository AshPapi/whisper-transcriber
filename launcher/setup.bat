@echo off
title Whisper Transcriber — Setup
cd /d "%~dp0"

echo ========================================
echo  Whisper Transcriber Setup
echo ========================================
echo.

REM ── Python dependencies ───────────────────────────────────────────────────
echo [1/3] Installing Python dependencies...
cd /d "%~dp0..\python_backend"
pip install -r requirements.txt
if errorlevel 1 (
    echo ERROR: Failed to install Python dependencies.
    pause
    exit /b 1
)
echo.

REM ── Flutter dependencies ──────────────────────────────────────────────────
echo [2/3] Installing Flutter dependencies...
cd /d "%~dp0..\flutter_ui"
flutter pub get
if errorlevel 1 (
    echo ERROR: Flutter not found or pub get failed.
    echo Make sure Flutter SDK is installed and in PATH.
    pause
    exit /b 1
)
echo.

REM ── Build Flutter Windows app ─────────────────────────────────────────────
echo [3/3] Building Flutter Windows app...
flutter build windows --release
if errorlevel 1 (
    echo ERROR: Flutter build failed.
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Setup complete! Run launcher\run.bat
echo ========================================
pause
