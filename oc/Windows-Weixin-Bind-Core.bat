@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title U盘虾 WeChat QR Bind (Core)

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LOG_FILE=%TEMP%\uclaw-weixin-bind.log"

> "%LOG_FILE%" echo [UCLAW] WeChat bind started
>> "%LOG_FILE%" echo [UCLAW] ScriptDir=%SCRIPT_DIR%

set "APP_DIR=%SCRIPT_DIR%\app"
if exist "%APP_DIR%\core-win" if not exist "%APP_DIR%\core" ren "%APP_DIR%\core-win" core

set "CORE_DIR=%APP_DIR%\core"
set "DATA_DIR=%SCRIPT_DIR%\data"
set "STATE_DIR=%DATA_DIR%\.openclaw"
set "CONFIG_PATH=%STATE_DIR%\openclaw.json"
set "NODE_DIR=%APP_DIR%\runtime\node-win-x64"
set "NODE_BIN=%NODE_DIR%\node.exe"
set "OPENCLAW_MJS=%CORE_DIR%\node_modules\openclaw\openclaw.mjs"
set "PLUGIN_JSON=%STATE_DIR%\extensions\openclaw-weixin\openclaw.plugin.json"
set "TMP_BIN_DIR=%TEMP%\uclaw-open-bind-bin"

if not exist "%NODE_BIN%" goto :err_node
if not exist "%OPENCLAW_MJS%" goto :err_openclaw
if not exist "%CORE_DIR%" goto :err_core
if not exist "%PLUGIN_JSON%" goto :err_plugin

if not exist "%DATA_DIR%" mkdir "%DATA_DIR%" >nul 2>nul
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul
if not exist "%DATA_DIR%\memory" mkdir "%DATA_DIR%\memory" >nul 2>nul
if not exist "%DATA_DIR%\backups" mkdir "%DATA_DIR%\backups" >nul 2>nul
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs" >nul 2>nul
if not exist "%TMP_BIN_DIR%" mkdir "%TMP_BIN_DIR%" >nul 2>nul

set "OPENCLAW_HOME=%DATA_DIR%"
set "OPENCLAW_STATE_DIR=%STATE_DIR%"
set "OPENCLAW_CONFIG_PATH=%CONFIG_PATH%"

> "%TMP_BIN_DIR%\openclaw.cmd" (
  echo @echo off
  echo "%NODE_BIN%" "%OPENCLAW_MJS%" %%*
)

set "PATH=%TMP_BIN_DIR%;%CORE_DIR%\node_modules\.bin;%NODE_DIR%;%PATH%"

for /d %%D in ("%STATE_DIR%\extensions\.openclaw-install-stage-*") do (
  rmdir /s /q "%%~fD" >nul 2>nul
)

cls
echo ========================================
echo   U盘虾 WeChat QR Bind (Windows)
echo   Login only, no reinstall
echo ========================================
echo State: %OPENCLAW_STATE_DIR%
echo Log  : %LOG_FILE%
echo.

>> "%LOG_FILE%" echo [UCLAW] Starting QR login...
cd /d "%CORE_DIR%" >nul 2>nul

REM IMPORTANT: do not redirect this command, so QR code shows in terminal.
"%NODE_BIN%" "%OPENCLAW_MJS%" channels login --channel openclaw-weixin
if errorlevel 1 goto :err_login

"%NODE_BIN%" "%OPENCLAW_MJS%" gateway restart >> "%LOG_FILE%" 2>&1

echo.
echo [OK] WeChat QR bind completed.
>> "%LOG_FILE%" echo [UCLAW] WeChat QR bind completed.
echo.
pause
exit /b 0

:err_node
echo [ERROR] Node not found:
echo %NODE_BIN%
>> "%LOG_FILE%" echo [UCLAW] Node not found: %NODE_BIN%
pause
exit /b 1

:err_openclaw
echo [ERROR] openclaw.mjs not found:
echo %OPENCLAW_MJS%
>> "%LOG_FILE%" echo [UCLAW] openclaw.mjs not found: %OPENCLAW_MJS%
pause
exit /b 1

:err_core
echo [ERROR] core folder not found:
echo %CORE_DIR%
>> "%LOG_FILE%" echo [UCLAW] core folder not found: %CORE_DIR%
pause
exit /b 1

:err_plugin
echo [ERROR] WeChat plugin is not installed:
echo %PLUGIN_JSON%
>> "%LOG_FILE%" echo [UCLAW] plugin missing: %PLUGIN_JSON%
echo Please install plugin first, then run bind.
pause
exit /b 1

:err_login
echo.
echo [ERROR] WeChat QR bind failed.
echo Check log: %LOG_FILE%
>> "%LOG_FILE%" echo [UCLAW] QR bind failed.
echo.
pause
exit /b 1
