# Checks that every .ps1/.mjs called by bin/*.cmd exists (%~dp0 resolved to bin\, absolute paths checked as they are); exits 1 if any is missing, else prints OK.
param([string]$BinDir = $PSScriptRoot)

$BinDir = [IO.Path]::GetFullPath($BinDir).TrimEnd('\')
# A target is a quoted or bare token ending in .ps1/.mjs.
$targetRx = '"(?<t>[^"]*?\.(?:ps1|mjs))"|(?<t>[^\s"&|<>()]+\.(?:ps1|mjs))(?![\w.])'
$dp0Rx = '(?i)%~s?dps?0'   # %~dp0, %~sdp0, %~dps0 = folder of the .cmd, with a trailing backslash
$cmds = @(Get-ChildItem -Path (Join-Path $BinDir '*.cmd') -File)
if ($cmds.Count -eq 0) { Write-Host "No .cmd files in $BinDir"; exit 1 }

$bad = @()
foreach ($f in $cmds) {
    $found = 0
    foreach ($line in Get-Content -LiteralPath $f.FullName) {
        if ($line -match '^\s*@?\s*(rem(\s|$)|::|echo[\s.])') { continue }   # comments and help text are not calls
        foreach ($m in [regex]::Matches($line, $targetRx)) {
            $found++
            $raw = $m.Groups['t'].Value
            $path = $raw -replace $dp0Rx, ($BinDir.Replace('$', '$$') + '\')
            $path = [Environment]::ExpandEnvironmentVariables($path)
            if ($path -match '%') {
                Write-Host "  $($f.Name): cannot resolve $raw"
                $bad += $f.Name; continue
            }
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $BinDir $path }   # bare name = expected in bin\
            $path = [IO.Path]::GetFullPath($path)
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Write-Host "  $($f.Name): ok $raw"
            } else {
                Write-Host "  $($f.Name): MISSING $raw -> $path"
                $bad += $f.Name
            }
        }
    }
    if (-not $found) { Write-Host "  $($f.Name): calls no .ps1/.mjs" }
}
if ($bad) {
    Write-Host "Missing targets in: $(($bad | Select-Object -Unique) -join ', ')"
    exit 1
}
Write-Host 'OK'
exit 0
