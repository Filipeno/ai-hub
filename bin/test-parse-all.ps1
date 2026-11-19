# Parse all PowerShell files in the bin directory and check for syntax errors
# If any file has syntax errors, list them and exit with code 1
# Otherwise, print "OK" and exit with code 0

$ErrorCount = 0
$ErrorFiles = @()

# Get all .ps1 files in bin directory
$PowerShellFiles = Get-ChildItem -Path "bin" -Filter "*.ps1"

foreach ($File in $PowerShellFiles) {
    try {
        # Parse the file using PowerShell's parser
        [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null)
    }
    catch {
        # If parsing fails, add to error list
        $ErrorCount++
        $ErrorFiles += $File.Name
    }
}

if ($ErrorCount -gt 0) {
    Write-Host "Syntax errors found in the following files:"
    foreach ($ErrorFile in $ErrorFiles) {
        Write-Host "  $ErrorFile"
    }
    exit 1
}
else {
    Write-Host "OK"
    exit 0
}