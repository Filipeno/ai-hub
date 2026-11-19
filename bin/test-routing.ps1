# Checks routing.json: exits 1 if it is not valid JSON or a top-level entry is null or empty, else prints OK (-SelfTest also runs failure fixtures).
param(
    [string]$Path = (Join-Path $PSScriptRoot '..\routing.json'),
    [switch]$SelfTest
)

# Empty = null, blank string, empty array, or an object with no properties ({} from ConvertFrom-Json is a PSCustomObject).
function Test-Empty($Value) {
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return @($Value.PSObject.Properties).Count -eq 0 }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count -eq 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -eq 0 }
    return $false
}

function Get-RoutingProblems([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return "file not found: $File" }
    $raw = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'file is empty' }
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return "invalid JSON: $($_.Exception.Message)" }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) { return 'top level is not a JSON object' }
    $props = @($json.PSObject.Properties)
    if ($props.Count -eq 0) { return 'no top-level entries' }
    foreach ($p in $props) {
        if (Test-Empty $p.Value) { "entry '$($p.Name)' is null or empty" }
    }
}

if ($SelfTest) {
    # Each fixture is run through this script in a child process, so the real exit code is checked.
    $cases = [ordered]@{
        'valid'        = 0, '{"a":"x","b":{"c":1},"c":[1],"d":false,"e":0}'
        'invalid-json' = 1, '{"a": "x",'
        'empty-object' = 1, '{"a":"x","b":{}}'
        'null-entry'   = 1, '{"a":"x","b":null}'
        'blank-string' = 1, '{"a":"  "}'
        'empty-array'  = 1, '{"a":[]}'
        'no-entries'   = 1, '{}'
        'not-object'   = 1, '[1,2]'
        'empty-file'   = 1, ''
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('test-routing-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $shell = (Get-Process -Id $PID).Path
    $failed = 0
    try {
        foreach ($name in $cases.Keys) {
            $want, $text = $cases[$name]
            $fixture = Join-Path $tmp "$name.json"
            [IO.File]::WriteAllText($fixture, $text)
            $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Path $fixture 2>&1
            $got = $LASTEXITCODE
            $mark = if ($got -eq $want) { 'pass' } else { $failed++; 'FAIL' }
            Write-Host ("  self-test {0} {1}: exit {2} (want {3}) {4}" -f $mark, $name, $got, $want, (@($out) -join ' | '))
        }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($failed) { Write-Host "Self-test failed: $failed case(s)"; exit 1 }
}

$problems = @(Get-RoutingProblems $Path)
if ($problems.Count) {
    foreach ($p in $problems) { Write-Host "  $(Split-Path -Leaf $Path): $p" }
    Write-Host 'routing.json check failed'
    exit 1
}
Write-Host 'OK'
exit 0
