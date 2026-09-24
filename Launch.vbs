Option Explicit
' ===========================================================================
'  Launch.vbs  -  API Model Tester launcher (no console window)
'
'  IMPORTANT: this file must stay PURE ASCII.
'  Windows Script Host decodes a .vbs using the system ANSI code page when the
'  file has no BOM. Any non-ASCII text (Chinese comments, Chinese MsgBox text)
'  turns into mojibake and the script fails to compile with:
'        800A0408  "Invalid character"
'  That is exactly why every string below is English / ASCII only.
'
'  Behaviour:
'    prefer PowerShell 7 (pwsh), fall back to Windows PowerShell 5.1
'    force one of them by setting environment variable AMT_SHELL=powershell
'    -STA is required for WinForms and is valid for both editions
'
'  Diagnostics:
'    writes %LOCALAPPDATA%\ApiModelTester\launch.log every run
'    (which interpreter was picked, the exact command line, candidates checked)
' ===========================================================================

Dim fso, sh, env, baseDir, ps1, exe, cmd, preferPwsh, i, cands
Dim progFiles, localApp, sysRoot, logDir, ts

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
Set env = sh.Environment("PROCESS")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = baseDir & "\ApiModelTester.ps1"
localApp = env("LOCALAPPDATA")
logDir = localApp & "\ApiModelTester"

If Not fso.FileExists(ps1) Then
    MsgBox "Main script not found:" & vbCrLf & ps1 & vbCrLf & vbCrLf & _
           "Please make sure this folder is complete.", 16, "API Model Tester"
    WScript.Quit 1
End If

progFiles = env("ProgramFiles")
sysRoot   = env("SystemRoot")
If sysRoot = "" Then sysRoot = "C:\Windows"

preferPwsh = True
If LCase(env("AMT_SHELL")) = "powershell" Then preferPwsh = False

cands = Array( _
    progFiles & "\PowerShell\7\pwsh.exe", _
    "D:\Program Files\PowerShell\7\pwsh.exe", _
    localApp & "\Microsoft\WindowsApps\pwsh.exe", _
    sysRoot & "\System32\WindowsPowerShell\v1.0\powershell.exe" _
)

exe = ""
If preferPwsh Then
    For i = 0 To UBound(cands) - 1
        If cands(i) <> "" Then
            If fso.FileExists(cands(i)) Then
                exe = cands(i)
                Exit For
            End If
        End If
    Next
End If

If exe = "" Then
    exe = sysRoot & "\System32\WindowsPowerShell\v1.0\powershell.exe"
End If
If Not fso.FileExists(exe) Then exe = "powershell.exe"

' -STA is required for WinForms; it is valid for both PowerShell editions.
' -ForceShow makes the app re-show its own window: we start it with window style 0
' (SW_HIDE, so no console ever flashes), and that hide state would otherwise be
' inherited by the WinForms main window, leaving the app running but invisible.
cmd = """" & exe & """ -NoProfile -STA -ExecutionPolicy Bypass -File """ & ps1 & """ -ForceShow"

' ---------- diagnostics log (best effort, never fatal) ----------
On Error Resume Next
If Not fso.FolderExists(logDir) Then fso.CreateFolder logDir
Set ts = fso.OpenTextFile(logDir & "\launch.log", 2, True)
ts.WriteLine "==== API Model Tester launch ===="
ts.WriteLine "time     : " & Now
ts.WriteLine "amtshell : [" & env("AMT_SHELL") & "]"
ts.WriteLine "basedir  : " & baseDir
ts.WriteLine "chosen   : " & exe
ts.WriteLine "command  : " & cmd
ts.WriteLine "candidates:"
For i = 0 To UBound(cands) - 1
    ts.WriteLine "  [" & i & "] exists=" & fso.FileExists(cands(i)) & "  " & cands(i)
Next
ts.WriteLine "result   : (see next line after the app starts)"
ts.Close
Err.Clear

sh.CurrentDirectory = baseDir
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    Dim msg
    msg = "Failed to start:" & vbCrLf & Err.Description & vbCrLf & vbCrLf & "Command:" & vbCrLf & cmd
    Set ts = fso.OpenTextFile(logDir & "\launch.log", 8, True)
    ts.WriteLine "ERROR    : 0x" & Hex(Err.Number) & "  " & Err.Description
    ts.Close
    MsgBox msg, 16, "API Model Tester"
    WScript.Quit 1
End If

Set ts = fso.OpenTextFile(logDir & "\launch.log", 8, True)
ts.WriteLine "result   : cmd started at " & Now
ts.Close
On Error GoTo 0
