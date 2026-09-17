# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-Syntax.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = @(Get-ChildItem -Path $here -Recurse -Include '*.ps1', '*.psm1' -File)
$bad = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($item in $errors) {
        $bad++
        Write-Host ('FAIL {0}:{1}: {2}' -f $file.Name, $item.Extent.StartLineNumber, $item.Message)
        Write-Host ('::error file={0},line={1}::{2}' -f $file.FullName, $item.Extent.StartLineNumber, $item.Message)
    }
}
Write-Host ('parsed {0} file(s) with {1} syntax error(s) on {2}' -f $files.Count, $bad, $PSVersionTable.PSVersion)
if ($bad -gt 0) {
    Write-Host ("FAILED {0}" -f $bad)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0