@echo off
chcp 65001 >nul

if not exist ".venv\Scripts\activate.bat" (
    echo [ОШИБКА] Виртуальное окружение не найдено.
    echo Сначала запустите setup.bat
    pause
    exit /b 1
)

call .venv\Scripts\activate.bat
python main.py
