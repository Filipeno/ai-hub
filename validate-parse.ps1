# Validate that our parse-all script works correctly by testing it on a known good file and a known bad file

# First, test with a valid PowerShell file
$validFile = "bin\ask.ps1"
Write-Host "Testing valid file: $validFile"

# Test parsing directly using the same method as our test script
$errors = @()
try {
    [System.Management.Automation.Language.Parser]::ParseFile($validFile, [ref]$errors, [ref]$null)
    Write-Host "Valid file parsed with $($errors.Count) errors"
} catch {
    Write-Host "Error parsing valid file: $_"
}

# Test with a deliberately broken file
Write-Host "`nCreating test file with syntax error..."
$brokenContent = @'
function Test-BrokenFunction {
    param(
        [string]$TestParam = "test"
    )

    Write-Host "This function has syntax error - missing closing brace"
}
'@

# Write to a temporary file
$tempFile = "temp-broken.ps1"
Set-Content $tempFile $brokenContent

Write-Host "Testing broken file: $tempFile"
$errors = @()
try {
    [System.Management.Automation.Language.Parser]::ParseFile($tempFile, [ref]$errors, [ref]$null)
    Write-Host "Broken file parsed with $($errors.Count) errors"
    if ($errors.Count -gt 0) {
        Write-Host "SUCCESS: Detected syntax error in broken file"
        foreach ($error in $errors) {
            Write-Host "  Error: $($error.Message)"
        }
    } else {
        Write-Host "FAILURE: Did not detect syntax error in broken file"
    }
} catch {
    Write-Host "Error parsing broken file: $_"
}

# Clean up
Remove-Item $tempFile -Force

Write-Host "`nValidation complete."