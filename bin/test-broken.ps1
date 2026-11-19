# This is a deliberately broken PowerShell script with syntax errors
param(
    [string]$TestParam = "test"
)

# Missing closing brace - this will cause a syntax error
function Test-Function {
    Write-Host "This function has a syntax error"
    # No closing brace here

Write-Host "This should not be reached due to syntax error"