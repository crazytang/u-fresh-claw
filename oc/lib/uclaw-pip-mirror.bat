@echo off
REM Windows 与 Mac 的 uclaw-python-runtime.sh 中 pip 镜像保持一致；在其它 .bat 里写：
REM   call "%UCLAW_DIR%lib\uclaw-pip-mirror.bat"
REM 或 call "%BASE_DIR%\lib\uclaw-pip-mirror.bat"（根目录一键启动等已解析出 BASE_DIR 时）
set "PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/"
set "PIP_TRUSTED_HOST=mirrors.aliyun.com"
set "PIP_DEFAULT_TIMEOUT=120"
