@echo off
rem windows-autostart-manager launcher: prefer Node, fall back to pure PowerShell; then open browser
cd /d %~dp0
netstat -ano | findstr ":8788.*LISTENING" >nul 2>&1 && (start http://127.0.0.1:8788/ & exit /b)
where node >nul 2>nul
if %errorlevel%==0 (
  start "autostart-manager" /min node scripts\server.mjs
) else (
  start "autostart-manager" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\server.ps1"
)
powershell -NoProfile -Command "1..12 | ForEach-Object { $p = 8788..8792 | Where-Object { Get-NetTCPConnection -LocalPort $_ -State Listen -ErrorAction SilentlyContinue } | Select-Object -First 1; if ($p) { Start-Process ('http://127.0.0.1:' + [string]$p); break }; Start-Sleep -Milliseconds 700 }"
