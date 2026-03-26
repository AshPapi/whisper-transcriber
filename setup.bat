@echo off
chcp 65001 >nul
echo.
echo ==========================================
echo   Whisper Transcriber — Установка
echo ==========================================
echo.

:: Проверяем наличие Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [ОШИБКА] Python не найден!
    echo.
    echo Установите Python 3.11 или новее:
    echo   https://www.python.org/downloads/
    echo.
    echo При установке отметьте галку "Add Python to PATH"
    pause
    exit /b 1
)

echo [OK] Python найден
echo.

:: Создаём виртуальное окружение
echo Создание виртуального окружения...
python -m venv .venv
if errorlevel 1 (
    echo [ОШИБКА] Не удалось создать виртуальное окружение
    pause
    exit /b 1
)

:: Активируем
call .venv\Scripts\activate.bat

:: Обновляем pip
echo Обновление pip...
python -m pip install --upgrade pip --quiet

:: Устанавливаем зависимости
echo Установка зависимостей (может занять несколько минут)...
pip install -r requirements.txt
if errorlevel 1 (
    echo [ОШИБКА] Не удалось установить зависимости
    pause
    exit /b 1
)

echo.
echo ==========================================
echo   Установка завершена!
echo ==========================================
echo.
echo Следующие шаги:
echo.
echo   1. Установите ffmpeg (если ещё не установлен):
echo      Откройте PowerShell и выполните:
echo        winget install ffmpeg
echo      или скачайте с https://ffmpeg.org/download.html
echo.
echo   2. Скачайте модель Whisper:
echo      Запустите: download_model.bat
echo.
echo   3. Запустите приложение:
echo      Запустите: run.bat
echo.
pause
