' Launches the widget with no console window.
' Keep this next to ClaudeUsageWidget.ps1. Shortcut it into shell:startup to autostart.
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\ClaudeUsageWidget.ps1""", 0, False
