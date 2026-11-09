# 纯 Python 直跑（Windows PowerShell）
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $env:AMANE_DATA) { throw '请先设置 $env:AMANE_DATA 指向 amane 的 data 目录' }
if (-not $env:AMANE_BASE) { $env:AMANE_BASE = 'http://127.0.0.1:8000' }
if (-not $env:DATA_DIR)   { $env:DATA_DIR   = (Join-Path (Get-Location) 'data') }
if (-not $env:PORT)       { $env:PORT       = '8770' }
python server\server.py @args
