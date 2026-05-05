@echo off
setlocal EnableExtensions
title U盘虾 Quick Terminal (USB)

set "UCLAW_DIR=%~dp0"
if "%UCLAW_DIR:~-1%"=="\" set "UCLAW_DIR=%UCLAW_DIR:~0,-1%"
set "APP_DIR=%UCLAW_DIR%\app"

if exist "%APP_DIR%\core-win" if not exist "%APP_DIR%\core" ren "%APP_DIR%\core-win" core

set "CORE_DIR=%APP_DIR%\core"
set "DATA_DIR=%UCLAW_DIR%\data"
set "STATE_DIR=%DATA_DIR%\.openclaw"
set "CONFIG_PATH=%STATE_DIR%\openclaw.json"
call "%UCLAW_DIR%\lib\uclaw-windows-runtime-dirs.bat"
set "NODE_BIN=%NODE_DIR%\node.exe"
set "OPENCLAW_MJS=%CORE_DIR%\node_modules\openclaw\openclaw.mjs"
set "TMP_BIN_DIR=%TEMP%\uclaw-open1-bin"

if not exist "%NODE_BIN%" goto :err_node
if not exist "%OPENCLAW_MJS%" goto :err_openclaw

if not exist "%DATA_DIR%" mkdir "%DATA_DIR%" >nul 2>nul
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul
if not exist "%DATA_DIR%\memory" mkdir "%DATA_DIR%\memory" >nul 2>nul
if not exist "%DATA_DIR%\backups" mkdir "%DATA_DIR%\backups" >nul 2>nul
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs" >nul 2>nul
if not exist "%TMP_BIN_DIR%" mkdir "%TMP_BIN_DIR%" >nul 2>nul

set "OPENCLAW_HOME=%DATA_DIR%"
set "OPENCLAW_STATE_DIR=%STATE_DIR%"
set "OPENCLAW_CONFIG_PATH=%CONFIG_PATH%"
call "%UCLAW_DIR%\lib\uclaw-pip-mirror.bat"

> "%TMP_BIN_DIR%\openclaw.cmd" (
  echo @echo off
  echo "%NODE_BIN%" "%OPENCLAW_MJS%" %%*
)

call "%UCLAW_DIR%\lib\uclaw-portable-path.bat" "%PY_DIR%" "%NODE_DIR%" "%TMP_BIN_DIR%;%CORE_DIR%\node_modules\.bin"

cls
echo ========================================
echo   U盘虾 Quick Terminal (Windows)
echo ========================================
echo UCLAW_DIR: %UCLAW_DIR%
echo CORE_DIR : %CORE_DIR%
echo STATE    : %OPENCLAW_STATE_DIR%

set "NODE_VER="
for /f "delims=" %%v in ('"%NODE_BIN%" --version 2^>nul') do set "NODE_VER=%%v"
if defined NODE_VER (
  echo Node     : %NODE_VER%
) else (
  echo Node     : NOT FOUND
)

set "OC_VER="
for /f "delims=" %%v in ('"%NODE_BIN%" "%OPENCLAW_MJS%" --version 2^>nul') do set "OC_VER=%%v"
if defined OC_VER (
  echo OpenClaw : %OC_VER%
) else (
  echo OpenClaw : NOT FOUND
)

echo.
echo Commands:
echo   openclaw --version
echo   openclaw doctor --repair
echo   openclaw gateway run --allow-unconfigured --force --port 18789
echo.

cd /d "%CORE_DIR%" >nul 2>nul
cmd /k
exit /b 0

:err_node
echo [ERROR] Node not found:
echo %NODE_BIN%
pause
exit /b 1

:err_openclaw
echo [ERROR] openclaw.mjs not found:
echo %OPENCLAW_MJS%
pause
exit /b 1
