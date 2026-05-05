@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
title UFreshClaw - Portable AI Agent

echo.
echo   ========================================
echo     UFreshClaw v1.1 - Portable AI Agent
echo   ========================================
echo.

set "UCLAW_DIR=%~dp0"

REM Support multiple portable layouts:
REM 1) root\app
REM 2) root\.uclaw-core\app
REM 3) root\oc\app
set "BASE_DIR=%UCLAW_DIR%oc"
if exist "%BASE_DIR%\app" goto :base_ok
set "BASE_DIR=%UCLAW_DIR%.uclaw-core"
if exist "%BASE_DIR%\app" goto :base_ok
set "BASE_DIR=%UCLAW_DIR%"
if exist "%BASE_DIR%\app" goto :base_ok

echo   [ERROR] portable core not found
echo   Expected one of:
echo     %UCLAW_DIR%oc\app
echo     %UCLAW_DIR%.uclaw-core\app
echo     %UCLAW_DIR%app
pause
exit /b 1

:base_ok
set "APP_DIR=%BASE_DIR%\app"

REM Migration shim: rename old core-win to core for existing USB users
if exist "%APP_DIR%\core-win" if not exist "%APP_DIR%\core" ren "%APP_DIR%\core-win" core

set "CORE_DIR=%APP_DIR%\core"
set "DATA_DIR=%BASE_DIR%\data"
set "STATE_DIR=%DATA_DIR%\.openclaw"
call "%BASE_DIR%\lib\uclaw-windows-runtime-dirs.bat"
set "NODE_BIN=%NODE_DIR%\node.exe"
set "NPM_BIN=%NODE_DIR%\npm.cmd"

set "OPENCLAW_HOME=%DATA_DIR%"
set "OPENCLAW_STATE_DIR=%STATE_DIR%"
set "OPENCLAW_CONFIG_PATH=%STATE_DIR%\openclaw.json"
set "OPENCLAW_MJS=%CORE_DIR%\node_modules\openclaw\openclaw.mjs"
set "CONFIG_SERVER=%BASE_DIR%\config-server"
set "NPM_REGISTRY=https://registry.npmmirror.com"
set "NODE_DISTURL=https://npmmirror.com/mirrors/node"
set "npm_config_registry=%NPM_REGISTRY%"
set "npm_config_disturl=%NODE_DISTURL%"
set "npm_config_audit=false"
set "npm_config_fund=false"
set "npm_config_fetch_retries=5"
set "npm_config_fetch_retry_mintimeout=2000"
set "npm_config_fetch_retry_maxtimeout=20000"
call "%BASE_DIR%\lib\uclaw-pip-mirror.bat"

REM Check runtime
if not exist "%NODE_BIN%" (
    echo   [ERROR] Node.js runtime not found
    echo   Please ensure app\runtime contains node-win-arm64 ^(ARM64^) or node-win-x64 ^(x64^)
    pause
    exit /b 1
)

for /f "tokens=*" %%v in ('"%NODE_BIN%" --version') do set NODE_VER=%%v
echo   Node.js: %NODE_VER%
if exist "%PY_DIR%\python.exe" (
    for /f "tokens=*" %%p in ('"%PY_DIR%\python.exe" --version') do echo   Python: %%p
) else (
    echo   Python: 未安装 ^(可选：在 Mac 上 bash oc/setup.sh --all-platforms 准备 U 盘^)
)
echo.

call "%BASE_DIR%\lib\uclaw-portable-path.bat" "%PY_DIR%" "%NODE_DIR%" ""

REM Init data directories
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"
if not exist "%DATA_DIR%\memory" mkdir "%DATA_DIR%\memory"
if not exist "%DATA_DIR%\backups" mkdir "%DATA_DIR%\backups"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"

REM Default config
if not exist "%STATE_DIR%\openclaw.json" (
    echo   First run - creating default config...
    echo {"gateway":{"mode":"local","auth":{"token":"uclaw"}}} > "%STATE_DIR%\openclaw.json"
    echo   Config created
    echo.
)

REM Sync config from legacy location
if exist "%DATA_DIR%\config.json" if not exist "%STATE_DIR%\openclaw.json" (
    copy "%DATA_DIR%\config.json" "%STATE_DIR%\openclaw.json" >nul
)

REM Check dependencies
if not exist "%CORE_DIR%\node_modules" (
    echo   First run - installing dependencies...
    echo   Using China mirror, please wait...
    echo.
    cd /d "%CORE_DIR%"
    call "%NPM_BIN%" install --registry=%NPM_REGISTRY%
    echo.
    echo   Dependencies installed!
	echo.
)

REM Cleanup old instance (same USB path only)
call :stop_old_instances

REM Sync portable tools.exec.pathPrepend in openclaw.json (current path + platform runtimes)
set "SYNC_JS=%BASE_DIR%\lib\uclaw-sync-openclaw-exec-path-prepend.js"
set "NODE_PREPEND="
if exist "%NODE_BIN%" set "NODE_PREPEND=%NODE_DIR%"
set "PY_PREPEND="
if exist "%PY_DIR%\python.exe" set "PY_PREPEND=%PY_DIR%"
if exist "%OPENCLAW_MJS%" if exist "%OPENCLAW_CONFIG_PATH%" if exist "%SYNC_JS%" (
    "%NODE_BIN%" "%SYNC_JS%" "%OPENCLAW_CONFIG_PATH%" "%NODE_PREPEND%" "%PY_PREPEND%"
)

REM Find available port
set PORT=18789
:check_port
netstat -an | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if %errorlevel%==0 (
    if "%PORT%"=="18789" echo   Default gateway port 18789 is still occupied by a non-OpenClaw process.
    echo   Port %PORT% in use, trying next...
    set /a PORT+=1
    if %PORT% gtr 18799 (
        echo   No available port 18789-18799
        pause
        exit /b 1
    )
    goto :check_port
)

REM Find available config center port
set CFG_PORT=18788
:check_cfg_port
if "%CFG_PORT%"=="%PORT%" (
    echo   Config port %CFG_PORT% reserved by gateway, trying next...
    set /a CFG_PORT+=1
    if %CFG_PORT% gtr 18798 (
        echo   No available config port 18788-18798
        pause
        exit /b 1
    )
    goto :check_cfg_port
)
netstat -an | findstr ":%CFG_PORT% " | findstr "LISTENING" >nul 2>&1
if %errorlevel%==0 (
    if "%CFG_PORT%"=="18788" echo   Default config port 18788 is still occupied by a non-OpenClaw process.
    echo   Config port %CFG_PORT% in use, trying next...
    set /a CFG_PORT+=1
    if %CFG_PORT% gtr 18798 (
        echo   No available config port 18788-18798
        pause
        exit /b 1
    )
    goto :check_cfg_port
)

echo   Starting OpenClaw on port %PORT%...
echo.

REM Start Config Server in background
echo   Starting Config Center on port %CFG_PORT%...
set "CONFIG_PORT=%CFG_PORT%"
set "GATEWAY_PORT=%PORT%"
start /B "" "%NODE_BIN%" "%CONFIG_SERVER%\server.js" >nul 2>&1

REM Wait for config server to start
timeout /t 2 /nobreak >nul

REM Open both Dashboard and Config Center
echo   Opening Dashboard and Config Center...
timeout /t 1 /nobreak >nul

REM Open OpenClaw Dashboard first
start "" http://127.0.0.1:%PORT%/#token=uclaw

REM Open Config Center (Node.js web UI) second
start "" http://127.0.0.1:%CFG_PORT%/?gatewayPort=%PORT%

echo   Browsers opened. Starting OpenClaw Gateway on port %PORT%...
echo   DO NOT close this window while using UFreshClaw!
echo.

cd /d "%CORE_DIR%"
"%NODE_BIN%" "%OPENCLAW_MJS%" gateway run --allow-unconfigured --force --port %PORT%

echo.
echo   OpenClaw stopped.
pause
goto :eof

:stop_old_instances
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" goto :eof

set "PID_FILE=%TEMP%\uclaw-pids-%RANDOM%%RANDOM%.txt"
call :collect_old_pids "%PID_FILE%"

set "OLD_FOUND=0"
for /f "usebackq delims=" %%P in ("%PID_FILE%") do (
    set "OLD_FOUND=1"
    echo   Detected old instance PID %%P, stopping...
    taskkill /PID %%P >nul 2>&1
)

if "!OLD_FOUND!"=="1" (
    timeout /t 1 /nobreak >nul
    call :collect_old_pids "%PID_FILE%"
    for /f "usebackq delims=" %%P in ("%PID_FILE%") do (
        taskkill /F /PID %%P >nul 2>&1
    )
    echo   Old instance stopped.
)

REM Prefer reclaiming default ports from OpenClaw leftovers before auto-fallback.
call :collect_old_pids "%PID_FILE%"
call :kill_openclaw_listener_on_port 18789 "%PID_FILE%"
call :kill_openclaw_listener_on_port 18788 "%PID_FILE%"

if exist "%PID_FILE%" del /f /q "%PID_FILE%" >nul 2>&1
goto :eof

:kill_openclaw_listener_on_port
set "TARGET_PORT=%~1"
set "PID_LIST_FILE=%~2"
set "PORT_FREED=0"
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%TARGET_PORT% .*LISTENING"') do (
    echo(%%P| findstr /R "^[0-9][0-9]*$" >nul 2>&1
    if not errorlevel 1 (
        findstr /X /C:"%%P" "%PID_LIST_FILE%" >nul 2>&1
        if not errorlevel 1 (
            echo   Reclaiming default port %TARGET_PORT% from OpenClaw PID %%P...
            taskkill /F /PID %%P >nul 2>&1
            set "PORT_FREED=1"
        )
    )
)
if "!PORT_FREED!"=="1" (
    timeout /t 1 /nobreak >nul
)
goto :eof

:collect_old_pids
set "OUT_FILE=%~1"
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $m=[Regex]::Escape($env:OPENCLAW_MJS); $c=[Regex]::Escape((Join-Path $env:CONFIG_SERVER 'server.js')); $g1='openclaw[\\/]+openclaw\.mjs'; $g2='config-server[\\/]+server\.js'; Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'node.exe' -and $_.CommandLine -and ( $_.CommandLine -match $m -or $_.CommandLine -match $c -or $_.CommandLine -match $g1 -or $_.CommandLine -match $g2 ) } | ForEach-Object { $_.ProcessId }" 2>nul | findstr /R "^[0-9][0-9]*$" > "%OUT_FILE%"
goto :eof
