@echo off
REM Prepend bundled Python then Node (+ npm .bin) so system Python/Node do not shadow U盘 runtime.
REM Mac 侧等价逻辑：uclaw-python-runtime.sh 中的 uclaw_export_path_portable_first。
REM Optional prefix first (e.g. TMP shim; core\node_modules\.bin) — align with Mac launcher order intent.
REM Usage: call "%BASE%\lib\uclaw-portable-path.bat" "<PY_DIR>" "<NODE_DIR>" "<PREFIX;optional;>"
REM   PY_DIR or PREFIX may be empty. NODE_DIR is required when calling from one-click launch (node exists).

set "UCLAW_HEAD=%~3"
if not "%UCLAW_HEAD%"=="" if not "%UCLAW_HEAD:~-1%"==";" set "UCLAW_HEAD=%UCLAW_HEAD%;"
if not "%~1"=="" if exist "%~1\python.exe" set "UCLAW_HEAD=%UCLAW_HEAD%%~1;"
if not "%~2"=="" if exist "%~2\node.exe" (
  set "UCLAW_HEAD=%UCLAW_HEAD%%~2;"
  if exist "%~2\node_modules\.bin\" set "UCLAW_HEAD=%UCLAW_HEAD%%~2\node_modules\.bin;"
)
if "%UCLAW_HEAD%"=="" goto :uclaw_pp_done
set "PATH=%UCLAW_HEAD%%PATH%"
:uclaw_pp_done
set "UCLAW_HEAD="
goto :eof
