# Shared helpers: find the readable text files of a folder, skipping secrets, dependencies and build output.
# Dot-source it AFTER lib\hub.ps1:  . "$PSScriptRoot\lib\collect.ps1"
$script:CollectExt = '\.(md|txt|json|jsonc|lua|luau|py|js|mjs|ts|tsx|jsx|cs|cpp|c|h|hpp|java|kt|go|rs|html|css|yml|yaml|toml|cfg|ini|csv|ps1|cmd|sh|ino|sql|xml)$'
$script:CollectSkipDirs = '(^|\\)(node_modules|\.git|\.github|bin|obj|dist|build|out|Library|\.venv|venv|__pycache__|\.idea|\.vs|\.claude|\.codex|\.tmp[^\\]*|vaultwarden|scoped_dir[^\\]*|\.next|target|packages|locale|locales)(\\|$)'
$script:CollectSecretName = '(^|[\\._-])(env|secret|secrets|credential|credentials|token|tokens|password|passwords|passwd|apikey|api-keys|keystore|id_rsa)([\\._-]|$)|\.(pem|key|pfx|p12|jks|keystore|kdbx|sqlite|db|log|lock)$|package-lock\.json$|wrangler\.toml$|\.dev\.vars$|settings\.local\.json$'
$script:CollectSecretContent = 'AIza[0-9A-Za-z_\-]{30,}|AQ\.[0-9A-Za-z_\-]{30,}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|(?i)(password|passwd|secret|api[_-]?key|token)["'']?\s*[:=]\s*["''][^"'']{8,}'

# Resolves a name: a path as given, or <root>\<name> for each folder in sourceRoots (config.json).
function Resolve-SourcePath([string]$p) {
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    foreach ($root in @((Get-HubConfig).sourceRoots)) { if (Test-Path (Join-Path $root $p)) { return (Join-Path $root $p) } }
    return $null
}

# Returns @{ Path; Rel; Size } for every readable file under the given files/folders; secrets are skipped (count in $script:CollectSkipped).
function Get-SourceFiles([string[]]$Paths, [int]$MaxFileKb = 1500) {
    $script:CollectSkipped = 0
    # "pwsh -File x.ps1 -Source a,b" arrives as ONE string "a,b": split it unless it is a real path.
    $Paths = @($Paths | ForEach-Object { if ($_ -and -not (Test-Path $_) -and -not (Resolve-SourcePath $_) -and $_.Contains(',')) { $_ -split ',' } else { $_ } })
    foreach ($p in $Paths) {
        $full = Resolve-SourcePath $p
        if (-not $full) { continue }
        $item = Get-Item $full
        if (-not $item.PSIsContainer) { [pscustomobject]@{ Path = $item.FullName; Rel = $item.Name; Size = $item.Length }; continue }
        $rootLen = $item.FullName.TrimEnd('\').Length + 1
        Get-ChildItem $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($rootLen)
            if ($rel -match $script:CollectSkipDirs -or $_.Name -notmatch $script:CollectExt) { return }
            if ($_.Length -gt ($MaxFileKb * 1KB) -or $_.Name -match $script:CollectSecretName) { $script:CollectSkipped++; return }
            if ($_.Length -lt 1MB) {
                $body = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                if ($body -and $body -match $script:CollectSecretContent) { $script:CollectSkipped++; return }
            }
            [pscustomobject]@{ Path = $_.FullName; Rel = "$($item.Name)\$rel"; Size = $_.Length }
        }
    }
}
