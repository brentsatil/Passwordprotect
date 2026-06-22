@echo off
setlocal enableextensions
rem Double-click to open the drop window, or drag files onto this launcher.
rem -STA is required for the WPF dialogs; %* forwards any dropped file paths.

rem Prefer the full path to Windows PowerShell so a broken PATH can't stop us.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PasswordProtect.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo ------------------------------------------------------------------
  echo Password Protect exited with code %RC%.
  echo.
  echo A diagnostic report ^(if one was written^) is here:
  echo   %~dp0PasswordProtect-error.log
  echo.
  echo If a RED "running scripts is disabled on this system" message
  echo appeared above, your IT policy is blocking PowerShell scripts.
  echo Send that message ^(and the log above^) to whoever set this up.
  echo ------------------------------------------------------------------
  echo.
  pause
)
endlocal
