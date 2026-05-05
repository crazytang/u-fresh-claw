@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fI\"
set "TARGET_VERSION=%~1"
if "%TARGET_VERSION%"=="" set "TARGET_VERSION=latest"

set "APP_DIR=%ROOT_DIR%oc\app"
call "%ROOT_DIR%oc\lib\uclaw-windows-runtime-dirs.bat"
set "NODE_BIN=%NODE_DIR%\node.exe"
if not exist "%NODE_BIN%" set "NODE_BIN=node"

"%NODE_BIN%" "%SCRIPT_DIR%upgrade-openclaw.js" "%TARGET_VERSION%"
if errorlevel 1 (
  exit /b 1
)

echo.
echo Upgrade success.
exit /b 0
