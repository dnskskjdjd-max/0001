' Lanza run-local.ps1 sin abrir ninguna ventana (la tarea de Windows ejecuta este archivo cada 5 minutos)
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\run-local.ps1""", 0, False
