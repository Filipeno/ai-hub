# Parse all PowerShell files in the bin directory and check for syntax errors
# If any file has syntax errors, list them and exit with code 1
# Otherwise, print "OK" and exit with code 0

$ErrorCount = 0
$ErrorFiles = @()

# Get all .ps1 files in bin directory relative to this script's location
$PowerShellFiles = Get-ChildItem -Path "$PSScriptRoot\*.ps1"

foreach ($File in $PowerShellFiles) {
    # Skip this test script itself
    if ($File.Name -eq "test-parse-all.ps1") {
        continue
    }

    # Create a variable to capture errors
    $Errors = @()

    try {
        # Parse the file using PowerShell's parser and capture syntax errors
        [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$Errors, [ref]$null)

        # If we have errors, increment counter and add to list
        if ($Errors.Count -gt 0) {
            $ErrorCount++
            $ErrorFiles += $File.Name
        }
    }
    catch {
        # If parsing fails due to I/O issues, add to error list
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