@echo off
rem ===========================================================================
rem  Launch.cmd  -  fallback launcher for API Model Tester
rem
rem  Use this when the desktop shortcut (which goes through Launch.vbs) reports
rem  an error. It starts the main script directly with powershell.exe / pwsh.exe,
rem  so no script host is involved and there is nothing to compile.
rem
rem  NOTE: this file must stay PURE ASCII. cmd.exe parses a .cmd using the system
rem  ANSI code page, so non-ASCII characters (e.g. Chinese comments) would turn
rem  into mojibake bytes and can break the batch parser. Keep all text ASCII.
rem ===========================================================================
setlocal

set "PS1=%~dp0ApiModelTester.ps1"
if not exist "%PS1%" (
    echo [ERROR] Main script not found:
    echo         %PS1%
    echo         Please make sure this folder is complete.
    pause
    exit /b 1
)

set "PSEXE=powershell.exe"
where pwsh >nul 2>nul
if %errorlevel%==0 set "PSEXE=pwsh.exe"

start "" %PSEXE% -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"

exit /b 0
