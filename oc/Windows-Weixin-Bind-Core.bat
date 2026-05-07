@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title UFreshClaw WeChat QR Bind (Core)

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LOG_FILE=%TEMP%\uclaw-weixin-bind.log"

> "%LOG_FILE%" echo [UCLAW] WeChat bind started
>> "%LOG_FILE%" echo [UCLAW] ScriptDir=%SCRIPT_DIR%
>> "%LOG_FILE%" echo [UCLAW] ScriptVersion=offline-first-20260425

set "APP_DIR=%SCRIPT_DIR%\app"
if exist "%APP_DIR%\core-win" if not exist "%APP_DIR%\core" ren "%APP_DIR%\core-win" core

set "CORE_DIR=%APP_DIR%\core"
set "DATA_DIR=%SCRIPT_DIR%\data"
set "STATE_DIR=%DATA_DIR%\.openclaw"
set "CONFIG_PATH=%STATE_DIR%\openclaw.json"
call "%SCRIPT_DIR%\lib\uclaw-windows-runtime-dirs.bat"
set "NODE_BIN=%NODE_DIR%\node.exe"
set "OPENCLAW_MJS=%CORE_DIR%\node_modules\openclaw\openclaw.mjs"
set "PLUGIN_DIR=%STATE_DIR%\extensions\openclaw-weixin"
set "PLUGIN_JSON=%PLUGIN_DIR%\openclaw.plugin.json"
set "PLUGIN_QRCODE_PKG=%PLUGIN_DIR%\node_modules\qrcode-terminal\package.json"
set "PLUGIN_ZOD_PKG=%PLUGIN_DIR%\node_modules\zod\package.json"
set "TMP_BIN_DIR=%TEMP%\uclaw-open-bind-bin"
set "WEIXIN_PLUGIN_PKG=@tencent-weixin/openclaw-weixin"
set "LOCAL_PLUGIN_TGZ=%SCRIPT_DIR%\plugins\openclaw-weixin.tgz"

if not exist "%NODE_BIN%" goto :err_node
if not exist "%OPENCLAW_MJS%" goto :err_openclaw
if not exist "%CORE_DIR%" goto :err_core

if not exist "%DATA_DIR%" mkdir "%DATA_DIR%" >nul 2>nul
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul
if not exist "%DATA_DIR%\memory" mkdir "%DATA_DIR%\memory" >nul 2>nul
if not exist "%DATA_DIR%\backups" mkdir "%DATA_DIR%\backups" >nul 2>nul
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs" >nul 2>nul
if not exist "%TMP_BIN_DIR%" mkdir "%TMP_BIN_DIR%" >nul 2>nul

set "OPENCLAW_HOME=%DATA_DIR%"
set "OPENCLAW_STATE_DIR=%STATE_DIR%"
set "OPENCLAW_CONFIG_PATH=%CONFIG_PATH%"
call "%SCRIPT_DIR%\lib\uclaw-pip-mirror.bat"
set "NPM_REGISTRY=https://registry.npmmirror.com"
set "NODE_DISTURL=https://npmmirror.com/mirrors/node"
set "npm_config_registry=%NPM_REGISTRY%"
set "npm_config_disturl=%NODE_DISTURL%"
set "npm_config_audit=false"
set "npm_config_fund=false"
set "npm_config_fetch_retries=5"
set "npm_config_fetch_retry_mintimeout=2000"
set "npm_config_fetch_retry_maxtimeout=20000"
>> "%LOG_FILE%" echo [UCLAW] npm registry=%npm_config_registry%

> "%TMP_BIN_DIR%\openclaw.cmd" (
  echo @echo off
  echo "%NODE_BIN%" "%OPENCLAW_MJS%" %%*
)

call "%SCRIPT_DIR%\lib\uclaw-portable-path.bat" "%PY_DIR%" "%NODE_DIR%" "%TMP_BIN_DIR%;%CORE_DIR%\node_modules\.bin"

if exist "%STATE_DIR%\extensions" (
  for /d %%D in ("%STATE_DIR%\extensions\.openclaw-install-stage-*") do (
    rmdir /s /q "%%~fD" >nul 2>nul
  )
)

if not exist "%PLUGIN_JSON%" call :install_plugin
if exist "%PLUGIN_JSON%" if not exist "%PLUGIN_QRCODE_PKG%" if exist "%LOCAL_PLUGIN_TGZ%" call :install_plugin_offline
if exist "%PLUGIN_JSON%" if not exist "%PLUGIN_ZOD_PKG%" if exist "%LOCAL_PLUGIN_TGZ%" call :install_plugin_offline
if not exist "%PLUGIN_JSON%" goto :err_plugin
if not exist "%PLUGIN_QRCODE_PKG%" goto :err_plugin_deps
if not exist "%PLUGIN_ZOD_PKG%" goto :err_plugin_deps

cls
echo ========================================
echo   UFreshClaw WeChat QR Bind (Windows)
echo   Login flow with auto plugin install
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

:install_plugin
set "INSTALL_SPEC=%WEIXIN_PLUGIN_PKG%"
if exist "%LOCAL_PLUGIN_TGZ%" (
  echo [INFO] WeChat plugin not found, installing from bundled local package...
  echo [INFO] Script version: offline-first-20260425
  >> "%LOG_FILE%" echo [UCLAW] Plugin missing, offline install from local package: %LOCAL_PLUGIN_TGZ%
  call :install_plugin_offline
  goto :eof
) else (
  echo [INFO] WeChat plugin not found, local package missing, fallback to registry install...
  >> "%LOG_FILE%" echo [UCLAW] Local package missing, fallback install: %WEIXIN_PLUGIN_PKG%
)
cd /d "%CORE_DIR%" >nul 2>nul
"%NODE_BIN%" "%OPENCLAW_MJS%" plugins install "%INSTALL_SPEC%" >> "%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [WARN] Standard plugin install failed.
  >> "%LOG_FILE%" echo [UCLAW] Standard plugin install failed
  if exist "%LOCAL_PLUGIN_TGZ%" call :install_plugin_offline
) else (
  echo [OK] Plugin installed.
  >> "%LOG_FILE%" echo [UCLAW] Plugin installed
)
goto :eof

:install_plugin_offline
echo [INFO] Trying offline plugin install...
>> "%LOG_FILE%" echo [UCLAW] Trying offline plugin install
set "STAGE_DIR=%TEMP%\uclaw-weixin-plugin-stage"
if exist "%STAGE_DIR%" rmdir /s /q "%STAGE_DIR%" >nul 2>nul
mkdir "%STAGE_DIR%" >> "%LOG_FILE%" 2>&1
if errorlevel 1 goto :offline_fail

tar -xzf "%LOCAL_PLUGIN_TGZ%" -C "%STAGE_DIR%" >> "%LOG_FILE%" 2>&1
if errorlevel 1 goto :offline_fail
if not exist "%STAGE_DIR%\package\openclaw.plugin.json" goto :offline_fail

if not exist "%STATE_DIR%\extensions" mkdir "%STATE_DIR%\extensions" >> "%LOG_FILE%" 2>&1
if exist "%PLUGIN_DIR%" rmdir /s /q "%PLUGIN_DIR%" >> "%LOG_FILE%" 2>&1
mkdir "%PLUGIN_DIR%" >> "%LOG_FILE%" 2>&1
if errorlevel 1 goto :offline_fail
xcopy "%STAGE_DIR%\package\*" "%PLUGIN_DIR%\" /E /I /Y /Q >> "%LOG_FILE%" 2>&1
if errorlevel 1 goto :offline_fail

if not exist "%PLUGIN_DIR%\node_modules" mkdir "%PLUGIN_DIR%\node_modules" >> "%LOG_FILE%" 2>&1
for %%P in (qrcode-terminal zod) do (
  if exist "%CORE_DIR%\node_modules\%%P" (
    if exist "%PLUGIN_DIR%\node_modules\%%P" rmdir /s /q "%PLUGIN_DIR%\node_modules\%%P" >> "%LOG_FILE%" 2>&1
    xcopy "%CORE_DIR%\node_modules\%%P" "%PLUGIN_DIR%\node_modules\%%P\" /E /I /Y /Q >> "%LOG_FILE%" 2>&1
  ) else (
    echo [WARN] Missing bundled dependency: %%P
    >> "%LOG_FILE%" echo [UCLAW] Missing bundled dependency: %%P
  )
)

call :enable_plugin_config
if not exist "%PLUGIN_JSON%" goto :offline_fail
if not exist "%PLUGIN_QRCODE_PKG%" goto :offline_fail
if not exist "%PLUGIN_ZOD_PKG%" goto :offline_fail
echo [OK] Plugin installed offline.
>> "%LOG_FILE%" echo [UCLAW] Plugin installed offline
if exist "%STAGE_DIR%" rmdir /s /q "%STAGE_DIR%" >nul 2>nul
goto :eof

:offline_fail
echo [ERROR] Offline plugin install failed.
>> "%LOG_FILE%" echo [UCLAW] Offline plugin install failed
if exist "%STAGE_DIR%" rmdir /s /q "%STAGE_DIR%" >nul 2>nul
goto :eof

:enable_plugin_config
set "CONFIG_JS=%TEMP%\uclaw-enable-weixin-plugin.js"
> "%CONFIG_JS%" (
  echo const fs = require('fs'^);
  echo const path = require('path'^);
  echo const p = process.argv[2];
  echo const installPath = process.argv[3];
  echo let cfg = {};
  echo try { if (fs.existsSync(p^)^) cfg = JSON.parse(fs.readFileSync(p, 'utf8'^)^); } catch { cfg = {}; }
  echo cfg.plugins = cfg.plugins ^|^| {};
  echo cfg.plugins.entries = cfg.plugins.entries ^|^| {};
  echo cfg.plugins.installs = cfg.plugins.installs ^|^| {};
  echo cfg.plugins.entries['openclaw-weixin'] = { enabled: true };
  echo cfg.plugins.installs['openclaw-weixin'] = { source: 'archive', sourcePath: 'plugins/openclaw-weixin.tgz', installPath, version: '2.1.8', installedAt: new Date^(^).toISOString^(^) };
  echo cfg.meta = cfg.meta ^|^| {};
  echo cfg.meta.lastTouchedAt = new Date^(^).toISOString^(^);
  echo fs.mkdirSync(path.dirname(p^), { recursive: true }^);
  echo fs.writeFileSync(p, JSON.stringify(cfg, null, 2^) + '\n'^);
)
"%NODE_BIN%" "%CONFIG_JS%" "%CONFIG_PATH%" "%PLUGIN_DIR%" >> "%LOG_FILE%" 2>&1
del "%CONFIG_JS%" >nul 2>nul
goto :eof

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
echo Automatic plugin installation failed. Please check the log.
echo Log: %LOG_FILE%
pause
exit /b 1

:err_plugin_deps
echo [ERROR] WeChat plugin dependencies are not installed:
if not exist "%PLUGIN_QRCODE_PKG%" echo %PLUGIN_QRCODE_PKG%
if not exist "%PLUGIN_ZOD_PKG%" echo %PLUGIN_ZOD_PKG%
>> "%LOG_FILE%" echo [UCLAW] plugin dependency missing
echo Automatic plugin installation failed. Please check the log.
echo Log: %LOG_FILE%
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
