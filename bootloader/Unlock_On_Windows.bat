@echo off
:: ====================================================================
::           SOUL STONE - 1-CLICK WINDOWS 10/11 UNLOCKER (WSL2)
:: ====================================================================
title Soul Stone Windows Unlocker
color 0b

echo.
echo  ================================================================
echo                    SOUL STONE ENCRYPTED DRIVE
echo  ================================================================
echo.
echo  Scanning physical drives connected to this PC...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance -Query 'SELECT DeviceID, Caption, Size, MediaType FROM Win32_DiskDrive' | Format-Table -AutoSize DeviceID, Caption, Size"

echo.
echo  ----------------------------------------------------------------
echo  Enter the PhysicalDrive ID of your SD Card / Soul Stone.
echo  (Example: Type '1' for \\.\PHYSICALDRIVE1, or '2' for \\.\PHYSICALDRIVE2)
echo  ----------------------------------------------------------------
set /p drive_num=" Drive Number: "

if "%drive_num%"=="" (
    echo.
    echo  [!] No drive number entered. Exiting.
    pause
    exit /b
)

echo.
echo  [*] Attaching \\.\PHYSICALDRIVE%drive_num% Partition 2 to WSL2...
echo.

wsl --mount \\.\PHYSICALDRIVE%drive_num% --partition 2

if %errorlevel% neq 0 (
    echo.
    echo  [!] WSL2 mount failed. Make sure PowerShell is running as Administrator
    echo      and that WSL2 is installed (run 'wsl --install' if needed).
    pause
    exit /b
)

echo.
echo  [+] Successfully attached!
echo  [*] Opening Windows File Explorer to your Soul Stone files...
echo.

start "" "\\wsl$\Ubuntu\mnt\wsl" 2>nul || start "" "\\wsl$"

echo  ================================================================
echo  When finished, close File Explorer and run:
echo    wsl --unmount \\.\PHYSICALDRIVE%drive_num%
echo  ================================================================
echo.
pause
