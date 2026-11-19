# This is a deliberately broken PowerShell script for testing
function Test-BrokenFunction {
    # Missing closing brace
    param(
        [string]$TestParam = "test"
    )

    Write-Host "This function has syntax error - missing closing brace"
}

# Call the function
$result = Test-BrokenFunction
Write-Host $result