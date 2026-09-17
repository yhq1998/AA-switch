# AA Switch - Windows environment probe (read-only).
# Run:  powershell -ExecutionPolicy Bypass -File probe.ps1
# Prints where Codex / Claude Code / Claude desktop keep their data on this PC, and saves the same text to
# aa-switch-probe.txt next to this script. It never prints secrets: JSON values whose name contains
# key / token / secret are shown as <redacted>, auth.json shows field names only.
# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

$ErrorActionPreference = 'SilentlyContinue'
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s = '') { $out.Add($s); Write-Host $s }
function Head([string]$s) { Say; Say "=== $s ===" }

function ListDir([string]$path, [int]$max = 40) {
  if (-not (Test-Path -LiteralPath $path)) { Say "  (missing) $path"; return }
  Say "  $path"
  $items = @(Get-ChildItem -LiteralPath $path -Force | Sort-Object Name)
  foreach ($i in ($items | Select-Object -First $max)) {
    if ($i.PSIsContainer) { Say ("    [dir]  {0}" -f $i.Name) }
    else { Say ("    {0,10}  {1}" -f $i.Length, $i.Name) }
  }
  if ($items.Count -gt $max) { Say ("    ... and {0} more" -f ($items.Count - $max)) }
}

function Redact($node, [string]$indent = '    ', [int]$depth = 0) {
  if ($depth -gt 3 -or $null -eq $node) { return }
  foreach ($p in $node.PSObject.Properties) {
    $v = $p.Value
    if ($p.Name -match '(?i)key|token|secret|password') { Say "$indent$($p.Name) = <redacted, present=$([bool]$v)>" }
    elseif ($v -is [System.Management.Automation.PSCustomObject]) { Say "$indent$($p.Name):"; Redact $v "$indent  " ($depth + 1) }
    elseif ($v -is [array]) { Say "$indent$($p.Name) = [$($v.Count) items] $((($v | Select-Object -First 5) | ForEach-Object { if ($_ -is [string]) { $_ } else { '{..}' } }) -join ', ')" }
    else { Say "$indent$($p.Name) = $v" }
  }
}

function ShowJson([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { Say "  (missing) $path"; return }
  Say "  $path"
  try { Redact (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Say "    (not valid JSON: $($_.Exception.Message))" }
}

Head 'System'
$os = Get-CimInstance Win32_OperatingSystem
Say "  OS: $($os.Caption) $($os.Version) $($os.OSArchitecture)"
Say "  PowerShell: $($PSVersionTable.PSVersion)"
Say "  USERPROFILE: $env:USERPROFILE"
Say "  APPDATA: $env:APPDATA"
Say "  LOCALAPPDATA: $env:LOCALAPPDATA"
Say "  .NET desktop runtimes: $((& dotnet --list-runtimes 2>$null | Select-String 'WindowsDesktop') -join '; ')"

Head 'Command line tools'
foreach ($n in 'codex', 'claude', 'sqlite3', 'git', 'bash', 'wsl') {
  $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { Say "  $n -> $($c.Source)" } else { Say "  $n -> (not found)" }
}
Say "  codex --version: $(& codex --version 2>$null)"
Say "  claude --version: $(& claude --version 2>$null)"
Say "  CODEX_HOME=$env:CODEX_HOME  CLAUDE_CONFIG_DIR=$env:CLAUDE_CONFIG_DIR"
Say "  ANTHROPIC_BASE_URL set: $([bool]$env:ANTHROPIC_BASE_URL)  ANTHROPIC_AUTH_TOKEN set: $([bool]$env:ANTHROPIC_AUTH_TOKEN)  OPENAI_API_KEY set: $([bool]$env:OPENAI_API_KEY)"

Head 'Codex data (~\.codex)'
$codex = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
ListDir $codex
$cfg = Join-Path $codex 'config.toml'
if (Test-Path -LiteralPath $cfg) {
  Say '  config.toml (section headers, model_provider, base_url, env_key, wire_api lines only):'
  Get-Content -LiteralPath $cfg -Encoding UTF8 | Where-Object { $_ -match '^\s*(\[|model_provider|model\s*=|base_url|env_key|wire_api|name\s*=|requires_openai_auth|preferred_auth_method)' } | ForEach-Object { Say "    $_" }
}
$auth = Join-Path $codex 'auth.json'
if (Test-Path -LiteralPath $auth) {
  try {
    $a = Get-Content -LiteralPath $auth -Raw -Encoding UTF8 | ConvertFrom-Json
    Say "  auth.json fields: $(($a.PSObject.Properties | ForEach-Object { '{0}({1})' -f $_.Name, $(if ($null -eq $_.Value) { 'null' } else { 'set' }) }) -join ', ')"
    if ($a.auth_mode) { Say "  auth.json auth_mode = $($a.auth_mode)" }
  } catch { Say '  auth.json: not valid JSON' }
} else { Say '  auth.json: missing (Codex on Windows may keep login in Credential Manager instead)' }
$dbs = @(Get-ChildItem -LiteralPath $codex -Filter 'state_*.sqlite*' -Force)
Say "  state_*.sqlite files: $(($dbs | ForEach-Object { $_.Name }) -join ', ')"
foreach ($sub in 'sessions', 'archived_sessions') {
  $d = Join-Path $codex $sub
  if (Test-Path -LiteralPath $d) {
    $files = @(Get-ChildItem -LiteralPath $d -Recurse -Filter '*.jsonl' -File)
    Say "  ${sub}: $($files.Count) jsonl files"
    $f = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) {
      $first = Get-Content -LiteralPath $f.FullName -TotalCount 1 -Encoding UTF8
      $m = [regex]::Match($first, '"model_provider"\s*:\s*"([^"]*)"')
      Say "    newest: $($f.FullName.Substring($codex.Length))"
      Say "    first line length $($first.Length), model_provider match: '$($m.Value)'"
      Say "    first line top-level shape: $($first.Substring(0, [Math]::Min(120, $first.Length)) -replace '[A-Za-z]:\\\\[^"]*', '<path>')"
    }
  } else { Say "  ${sub}: (missing)" }
}

Head 'Claude Code data (~\.claude)'
$claude = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
ListDir $claude
ShowJson (Join-Path $claude 'settings.json')
$cj = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path -LiteralPath $cj) {
  try {
    $o = (Get-Content -LiteralPath $cj -Raw -Encoding UTF8 | ConvertFrom-Json).oauthAccount
    Say "  ~\.claude.json: oauthAccount present=$([bool]$o) accountUuid present=$([bool]$o.accountUuid) organizationUuid present=$([bool]$o.organizationUuid)"
  } catch { Say '  ~\.claude.json: not valid JSON' }
} else { Say '  ~\.claude.json: missing' }
Say "  .credentials.json present: $(Test-Path -LiteralPath (Join-Path $claude '.credentials.json'))"

Head 'Claude desktop data'
$roots = @((Join-Path $env:APPDATA 'Claude'), (Join-Path $env:APPDATA 'Claude-3p'), (Join-Path $env:LOCALAPPDATA 'Claude'), (Join-Path $env:LOCALAPPDATA 'Claude-3p'), (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))
$pk = Join-Path $env:LOCALAPPDATA 'Packages'
Get-ChildItem -LiteralPath $pk -Directory | Where-Object { $_.Name -match '(?i)claude|anthropic' } | ForEach-Object {
  Say "  MSIX package dir: $($_.FullName)"
  foreach ($r in 'LocalCache\Roaming', 'LocalCache\Local') {
    $p = Join-Path $_.FullName $r
    if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Directory | ForEach-Object { $roots += $_.FullName } }
  }
}
foreach ($r in $roots) {
  if (-not (Test-Path -LiteralPath $r)) { Say "  (missing) $r"; continue }
  ListDir $r 60
  ShowJson (Join-Path $r 'claude_desktop_config.json')
  $lib = Join-Path $r 'configLibrary'
  if (Test-Path -LiteralPath $lib) { Get-ChildItem -LiteralPath $lib -Filter '*.json' | ForEach-Object { ShowJson $_.FullName } }
  $cs = Join-Path $r 'claude-code-sessions'
  if (Test-Path -LiteralPath $cs) {
    Get-ChildItem -LiteralPath $cs -Directory | ForEach-Object {
      $acct = $_
      Get-ChildItem -LiteralPath $acct.FullName -Directory | ForEach-Object {
        $n = @(Get-ChildItem -LiteralPath $_.FullName -Filter 'local_*.json').Count
        $del = @(Get-ChildItem -LiteralPath $_.FullName -Filter 'deleted_*').Count
        Say "    claude-code-sessions\<acct $($acct.Name.Length) chars>\<org $($_.Name.Length) chars>: $n local_*.json, $del deleted_*"
      }
    }
  }
  $cc = Join-Path $r 'claude-code'
  if (Test-Path -LiteralPath $cc) { ListDir $cc 10 }
}

Head 'Installed apps'
Get-AppxPackage | Where-Object { $_.Name -match '(?i)claude|anthropic|openai|codex|chatgpt' } | ForEach-Object {
  Say "  MSIX: $($_.Name) $($_.Version)"
  Say "    PackageFamilyName: $($_.PackageFamilyName)"
  Say "    InstallLocation: $($_.InstallLocation)"
  try { ([xml](Get-Content -LiteralPath (Join-Path $_.InstallLocation 'AppxManifest.xml') -Raw)).Package.Applications.Application | ForEach-Object { Say "    AppId: $($_.Id)  Executable: $($_.Executable)" } } catch {}
}
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
  Get-ItemProperty $k | Where-Object { $_.DisplayName -match '(?i)claude|codex|chatgpt' } | ForEach-Object {
    Say "  Installer: $($_.DisplayName) $($_.DisplayVersion)"
    Say "    InstallLocation: $($_.InstallLocation)"
    Say "    DisplayIcon: $($_.DisplayIcon)"
  }
}
foreach ($sm in (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')) {
  Get-ChildItem -LiteralPath $sm -Recurse -Filter '*.lnk' | Where-Object { $_.BaseName -match '(?i)claude|codex|chatgpt' } | ForEach-Object {
    $t = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
    Say "  Shortcut: $($_.FullName)"
    Say "    -> $($t.TargetPath) $($t.Arguments)"
  }
}

Head 'Running processes (open Codex and Claude desktop before running this)'
Get-Process | Where-Object { $_.ProcessName -match '(?i)claude|codex|chatgpt' } | Group-Object ProcessName | ForEach-Object {
  $p = $_.Group | Select-Object -First 1
  $win = @($_.Group | Where-Object { $_.MainWindowHandle -ne 0 }).Count
  Say "  $($_.Name) x$($_.Count)  (with a main window: $win)"
  Say "    path: $($p.Path)"
}

Head 'Credential Manager entries (names only)'
& cmdkey /list | Select-String -Pattern '(?i)claude|codex|openai|anthropic|aa.?switch' | ForEach-Object { Say "  $($_.Line.Trim())" }

$report = Join-Path $PSScriptRoot 'aa-switch-probe.txt'
[System.IO.File]::WriteAllLines($report, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host
Write-Host "Saved to $report - please send this file (or paste the text above) back."
