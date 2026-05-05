@echo off
REM Portable Node/Python dirs under %APP_DIR%\runtime (Windows x64 vs ARM64).
REM Prereq: APP_DIR set to the bundle "app" directory (contains runtime\).
REM Detects WoA: PROCESSOR_ARCHITEW6432=ARM64 when running 32-bit cmd on ARM64.
if not defined APP_DIR goto :eof
set "NODE_DIR=%APP_DIR%\runtime\node-win-x64"
set "PY_DIR=%APP_DIR%\runtime\python-win-amd64"
set "UCLAW_NODE_ZIP_PLATFORM=win-x64"
set "UCLAW_WIN_ARM=0"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "UCLAW_WIN_ARM=1"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "UCLAW_WIN_ARM=1"
if "%UCLAW_WIN_ARM%"=="1" (
  set "NODE_DIR=%APP_DIR%\runtime\node-win-arm64"
  set "PY_DIR=%APP_DIR%\runtime\python-win-arm64"
  set "UCLAW_NODE_ZIP_PLATFORM=win-arm64"
)
set "UCLAW_WIN_ARM="
goto :eof
