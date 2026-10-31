' Starts the foobar2000 Discord Rich Presence script with no window at all
' (no console flash, no taskbar button). Meant for the Windows Startup folder.
Dim shell, fso, folder
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\foobar-discord-rpc.ps1""", 0, False
