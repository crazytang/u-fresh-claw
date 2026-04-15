@echo off
chcp 65001 >nul 2>&1
setlocal
set "ROOT=%~dp0"

echo 正在隐藏除两个启动器外的所有根目录文件...
for %%I in ("%ROOT%*") do (
  if /I not "%%~nxI"=="Mac-一键启动.command" if /I not "%%~nxI"=="Windows-一键启动.bat" if /I not "%%~nxI"=="Win-隐藏其它文件.bat" (
    attrib +h +s "%%~fI" >nul 2>&1
  )
)

echo 正在确保两个启动器可见...
attrib -h -s "%ROOT%Mac-一键启动.command" >nul 2>&1
attrib -h -s "%ROOT%Windows-一键启动.bat" >nul 2>&1

for %%I in ("%ROOT%Win-隐藏其它文件.bat") do attrib +h +s "%%~fI" >nul 2>&1

echo.
echo 完成。
echo 如果资源管理器仍看到灰色文件，请关闭“查看-隐藏的项目”后刷新。
pause
