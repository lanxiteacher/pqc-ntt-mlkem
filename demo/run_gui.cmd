@echo off
rem 双击运行「现场演示」GUI —— 直接 file:// 打开，不需要服务器、不连开发板
setlocal
set "HTML=%~dp0gui.html"
if not exist "%HTML%" (
  echo [ERROR] 找不到 %HTML%
  echo 请在 demo\ 目录下运行本脚本。
  pause
  exit /b 1
)
start "" "%HTML%"
endlocal
