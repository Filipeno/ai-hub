# Test script to verify our parsing approach works correctly
# This is a minimal PowerShell script that should parse without errors

param(
    [string]$TestParam = "test"
)

Write-Host "Testing parsing of PowerShell files"

# Simple function
function Test-Function {
    return "OK"
}

# Call the function
$result = Test-Function
Write-Host $result