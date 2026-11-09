@echo off
rem 构建 Amane-Harmony（未签名 HAP）。需先安装 DevEco Studio。
rem 若 SDK 不在默认位置，先 set DEVECO_HOME=<你的 DevEco Studio 目录>
setlocal
if "%DEVECO_HOME%"=="" set "DEVECO_HOME=%LOCALAPPDATA%\Huawei\DevEco Studio"
if not exist "%DEVECO_HOME%\sdk" (
  echo [!] 找不到 SDK：%DEVECO_HOME%\sdk
  echo     请设置 DEVECO_HOME 指向 DevEco Studio 安装目录。
  exit /b 1
)
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"
set "PATH=%DEVECO_HOME%\jbr\bin;%DEVECO_HOME%\tools\node;%PATH%"
cd /d "%~dp0"
"%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default assembleHap --no-daemon %*
