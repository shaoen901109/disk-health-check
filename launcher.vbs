' Runs a PowerShell script in this folder without flashing a console window.
' Usage: wscript.exe launcher.vbs <script.ps1> [args...]
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
args = ""
For i = 1 To WScript.Arguments.Count - 1
  args = args & " """ & WScript.Arguments(i) & """"
Next
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\" & WScript.Arguments(0) & """" & args
WScript.Quit sh.Run(cmd, 0, True)
