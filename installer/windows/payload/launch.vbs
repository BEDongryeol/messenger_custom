' Run launch.ps1 hidden (no console window flash)
Set sh = CreateObject("WScript.Shell")
data = sh.ExpandEnvironmentStrings("%APPDATA%") & "\DooraySkin"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & data & "\launch.ps1""", 0, False
