@echo off
rem 纯 Python 直跑（Windows cmd）
setlocal
if "%AMANE_DATA%"=="" (
  echo [!] 请先 set AMANE_DATA=^<amane 的 data 目录^>
  exit /b 1
)
if "%AMANE_BASE%"=="" set "AMANE_BASE=http://127.0.0.1:8000"
if "%DATA_DIR%"=="" set "DATA_DIR=%CD%\data"
if "%PORT%"=="" set "PORT=8770"
cd /d "%~dp0.."
python server\server.py %*
