@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "INSTALLER=%~dp0python-3.9.2-amd64.exe"
set "PACKAGES=%~dp0packages"
set "REQ=%~dp0requirements.txt"
set "TARGET=%LOCALAPPDATA%\Programs\Python\Python392Offline"
set "PYTHON=%TARGET%\python.exe"

echo ============================================================
echo Python 3.9.2 x64 + pip + requests/pandas/openpyxl offline setup
echo ============================================================
echo.

if not exist "%INSTALLER%" (
  echo [ERROR] Missing bundled installer:
  echo         %INSTALLER%
  exit /b 1
)

if not exist "%PACKAGES%" (
  echo [ERROR] Missing packages directory:
  echo         %PACKAGES%
  exit /b 1
)

if not exist "%REQ%" (
  echo [ERROR] Missing requirements.txt
  exit /b 1
)

echo [1/5] Installing CPython 3.9.2 x64 for current user...
echo       Target: %TARGET%
start /wait "" "%INSTALLER%" /quiet InstallAllUsers=0 TargetDir="%TARGET%" PrependPath=1 Include_pip=1 Include_launcher=0 InstallLauncherAllUsers=0 Include_test=0 AssociateFiles=0 Shortcuts=0
if errorlevel 1 (
  echo [ERROR] Python installer failed with exit code %ERRORLEVEL%.
  exit /b 1
)

if not exist "%PYTHON%" (
  echo [ERROR] python.exe was not created at:
  echo         %PYTHON%
  exit /b 1
)

echo [2/5] Verifying Python and bundled pip...
"%PYTHON%" --version
if errorlevel 1 exit /b 1
"%PYTHON%" -c "import sys,platform; assert sys.version_info[:3] == (3,9,2), sys.version; assert platform.architecture()[0] == '64bit'; print(sys.executable)"
if errorlevel 1 exit /b 1
"%PYTHON%" -m pip --version
if errorlevel 1 (
  echo [ERROR] Bundled pip is unavailable.
  exit /b 1
)

echo [3/5] Upgrading pip from local wheel only...
"%PYTHON%" -m pip install --no-index --find-links "%PACKAGES%" "pip<26"
if errorlevel 1 (
  echo [ERROR] Offline pip upgrade failed.
  exit /b 1
)

echo [4/5] Installing requested packages from local wheels only...
"%PYTHON%" -m pip install --no-index --find-links "%PACKAGES%" -r "%REQ%"
if errorlevel 1 (
  echo [ERROR] Offline dependency installation failed.
  exit /b 1
)

echo [5/5] Verifying imports and dependency consistency...
"%PYTHON%" -c "import requests,pandas,openpyxl; print('requests=', requests.__version__); print('pandas=', pandas.__version__); print('openpyxl=', openpyxl.__version__)"
if errorlevel 1 (
  echo [ERROR] Import verification failed.
  exit /b 1
)
"%PYTHON%" -m pip check
if errorlevel 1 (
  echo [ERROR] pip check failed.
  exit /b 1
)

echo.
echo ============================================================
echo [OK] Complete offline installation succeeded.
echo Python: %PYTHON%
echo.
echo A new CMD/PowerShell window can use the PATH change.
echo You can also run this exact interpreter immediately:
echo "%PYTHON%"
echo ============================================================
endlocal
