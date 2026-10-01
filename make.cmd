@echo off
rem Runs the Makefile on Windows.
rem If GNU make (make.exe) is present, it executes it directly.
rem Otherwise, it seamlessly delegates infrastructure commands to infra.ps1,
rem or offers to install make via winget.
setlocal
cd /d "%~dp0"

where make.exe >nul 2>nul
if not errorlevel 1 (
  make.exe %*
  exit /b %errorlevel%
)

set "MAKE_EXE=%LOCALAPPDATA%\Microsoft\WinGet\Links\make.exe"
if exist "%MAKE_EXE%" (
  "%MAKE_EXE%" %*
  exit /b %errorlevel%
)

rem If target is an infra command, delegate directly to infra.ps1
if not "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0infra.ps1" %*
  exit /b %errorlevel%
)

where winget.exe >nul 2>nul
if errorlevel 1 (
  echo GNU make is not installed and winget is not available.
  echo You can run commands via PowerShell: .\infra.ps1 help
  exit /b 1
)

echo GNU make is not installed.
choice /c yn /m "Install it now with winget (ezwinports.make)"
if errorlevel 2 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0infra.ps1" %*
  exit /b %errorlevel%
)

winget install --id ezwinports.make --exact --accept-source-agreements --accept-package-agreements
if exist "%MAKE_EXE%" (
  "%MAKE_EXE%" %*
  exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0infra.ps1" %*
exit /b %errorlevel%
