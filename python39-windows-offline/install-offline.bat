@echo off
setlocal
cd /d "%~dp0"

echo [INFO] Installing offline packages for Python 3.9...
python --version
if errorlevel 1 (
  echo [ERROR] Python was not found in PATH.
  exit /b 1
)

python -m pip install --no-index --find-links "%~dp0packages" -r "%~dp0requirements.txt"
if errorlevel 1 (
  echo [ERROR] Offline installation failed.
  exit /b 1
)

python -c "import requests,pandas,openpyxl; print('requests=', requests.__version__); print('pandas=', pandas.__version__); print('openpyxl=', openpyxl.__version__)"
if errorlevel 1 (
  echo [ERROR] Import verification failed.
  exit /b 1
)

echo [OK] Offline installation completed successfully.
endlocal
