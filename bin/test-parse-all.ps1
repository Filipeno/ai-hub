# Parses every bin/*.ps1 with the PowerShell parser; lists files with syntax errors and exits 1, else prints OK.
$bad = @()
foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot '*.ps1') -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) {
        $bad += $file.Name
        foreach ($e in $errors) { Write-Host ("  {0}:{1}: {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message) }
    }
}
if ($bad) {
    Write-Host "Syntax errors in: $($bad -join ', ')"
    exit 1
}
Write-Host 'OK'
exit 0
