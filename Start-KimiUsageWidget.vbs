Option Explicit

Dim fso, sh, dirName, ps1Path, exePath
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dirName = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = dirName & "\KimiUsageWidget.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "Widget script not found:" & vbCrLf & ps1Path, vbExclamation, "Kimi Usage Widget"
    WScript.Quit 1
End If

exePath = FindPowerShell()
If exePath = "" Then
    MsgBox "Neither pwsh.exe nor powershell.exe was found.", vbCritical, "Kimi Usage Widget"
    WScript.Quit 1
End If

sh.Run """" & exePath & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1Path & """", 0, False

' Prefer PowerShell 7 at its default install path, then anything named
' pwsh.exe on PATH, and finally fall back to Windows PowerShell 5.1.
Function FindPowerShell()
    Dim p, d
    FindPowerShell = ""
    p = "C:\Program Files\PowerShell\7\pwsh.exe"
    If fso.FileExists(p) Then
        FindPowerShell = p
        Exit Function
    End If
    For Each d In Split(sh.Environment("PROCESS")("PATH"), ";")
        If Len(d) > 0 Then
            p = fso.BuildPath(d, "pwsh.exe")
            If fso.FileExists(p) Then
                FindPowerShell = p
                Exit Function
            End If
        End If
    Next
    p = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
    If fso.FileExists(p) Then FindPowerShell = p
End Function
