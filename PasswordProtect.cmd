@echo off
rem Double-click to open the drop window, or drag files onto this launcher.
rem -STA is required for the WPF dialogs; %* forwards any dropped file paths.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PasswordProtect.ps1" %*
