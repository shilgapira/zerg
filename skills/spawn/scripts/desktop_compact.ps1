# Usage (run with: powershell -NoProfile -ExecutionPolicy Bypass -File desktop_compact.ps1 ...):
#   set --dir DIR [--autocompact auto|TOKENS]
#   restore --dir DIR
#   path --dir DIR                 (prints the folder's exact canonical path, the only cwd start_session accepts)
#   protocol --report-to SESSION   (prints the report-back text for the kickoff prompt)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Fail([string]$message) {
  [Console]::Error.WriteLine("spawn: $message")
  exit 1
}

function Normalize-Autocompact([string]$value) {
  $v = $value.ToLowerInvariant()
  if ($v -eq 'auto') { return 'auto' }
  if ($v -notmatch '^([0-9]{1,7})([km]?)$') { return $null }
  [long]$tokens = $Matches[1]
  switch ($Matches[2]) {
    'k' { $tokens *= 1000 }
    'm' { $tokens *= 1000000 }
    default { if ($tokens -lt 1000) { $tokens *= 1000 } }
  }
  if ($tokens -lt 100000 -or $tokens -gt 1000000) { return $null }
  return [string]$tokens
}

function Get-ReportProtocol([string]$name) {
  return "You are a worker session started by the Claude Code session named `"$name`". When you start, before " +
    "anything else, SendMessage to `"$name`" saying you are running. Whenever you finish the task or get blocked, " +
    "report to `"$name`" the same way. If your conversation was compacted (it continues from a summary of earlier " +
    "work), do not send the start message again; instead SendMessage to `"$name`" a short status: that you were " +
    "compacted, where the task stands, and what you are doing next."
}

function Get-CanonicalPath([string]$path) {
  $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
  $root = [IO.Path]::GetPathRoot($full)
  $canonical = $root.ToUpperInvariant()
  foreach ($part in $full.Substring($root.Length).Split('\')) {
    if ($part -eq '') { continue }
    $match = [IO.Directory]::GetFileSystemEntries($canonical, $part)
    if ($match.Count -ne 1) { Fail "cannot resolve $full" }
    $canonical = $match[0]
  }
  return $canonical
}

$utf8 = New-Object Text.UTF8Encoding $false

function Put([string]$file, [string]$text) {
  [IO.File]::WriteAllText("$file.tmp", $text, $utf8)
  Move-Item -LiteralPath "$file.tmp" -Destination $file -Force
}

function Get-Sha([string]$file) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash }

function Read-Settings([string]$file) {
  if (-not (Test-Path -LiteralPath $file)) { return [PSCustomObject]@{} }
  $text = [IO.File]::ReadAllText($file)
  if ($text.Trim() -eq '') { return [PSCustomObject]@{} }
  $obj = ConvertFrom-Json -InputObject $text
  # by full type name, since 5.1 can wrap a bare number or string in a PSObject too
  if ($null -eq $obj -or $obj.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
    throw 'settings is not a JSON object'
  }
  return $obj
}

# Returns the previous autoCompactWindow as JSON, or none; with $value, sets it to $value (JSON) or removes it (none).
function Json-Key([string]$file, [string]$value = $null) {
  $obj = Read-Settings $file
  $prop = $obj.PSObject.Properties['autoCompactWindow']
  $previous = if ($null -ne $prop) { ConvertTo-Json -InputObject $prop.Value -Depth 100 -Compress } else { 'none' }
  if ([string]::IsNullOrEmpty($value)) { return $previous }
  if ($value -eq 'none') {
    $obj.PSObject.Properties.Remove('autoCompactWindow')
  } else {
    $obj | Add-Member -NotePropertyName autoCompactWindow -NotePropertyValue ($value | ConvertFrom-Json) -Force
  }
  Put $file ((ConvertTo-Json -InputObject $obj -Depth 100) + "`n")
  return $previous
}

$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$dir = ''; $autocompact = 'auto'; $reportTo = ''; $after = 0
for ($i = 1; $i -lt $args.Count; $i += 2) {
  $flag = [string]$args[$i]
  if ($i + 1 -ge $args.Count) { Fail "$flag needs a value" }
  $val = [string]$args[$i + 1]
  switch ($flag) {
    '--dir' { $dir = $val }
    '--autocompact' { $autocompact = $val }
    '--report-to' { $reportTo = $val }
    '--after' { $after = [int]$val }
    default { Fail "unknown argument: $flag" }
  }
}

if ($cmd -eq 'protocol') {
  if ($reportTo -eq '') { Fail '--report-to is required' }
  Get-ReportProtocol $reportTo
  exit 0
}
if (@('set', 'restore', 'path') -notcontains $cmd) {
  Fail 'usage: desktop_compact.ps1 set|restore|path --dir DIR [--autocompact VALUE], or protocol --report-to SESSION'
}
if ($dir -eq '') { Fail '--dir is required' }
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "directory not found: $dir" }
$dir = Get-CanonicalPath $dir
if ($cmd -eq 'path') { $dir; exit 0 }

$settings = Join-Path (Join-Path $dir '.claude') 'settings.local.json'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) 'claude-spawn'
$dirHash = [BitConverter]::ToString(
  [Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($dir))).Replace('-', '').Substring(0, 16)
$state = Join-Path $stateRoot "compact-$($dirHash.ToLowerInvariant())"
$lock = "$state.lock"
$timeout = if ($env:SPAWN_COMPACT_TIMEOUT) { $env:SPAWN_COMPACT_TIMEOUT } else { '60' }
if ($timeout -notmatch '^[0-9]+$') { Fail "SPAWN_COMPACT_TIMEOUT must be a whole number of seconds: $timeout" }

function Acquire-Lock {
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  $owner = Join-Path $lock 'pid'
  for ($n = 0; $n -lt 50; $n++) {
    try {
      New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
      [IO.File]::WriteAllText($owner, "$PID")
      return
    } catch {}
    # a holder killed before its finally block leaves the lock behind
    $holder = Get-Content -LiteralPath $owner -Raw -ErrorAction SilentlyContinue
    if ($holder -match '^\s*([0-9]+)\s*$' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) -and
        (Get-Content -LiteralPath $owner -Raw -ErrorAction SilentlyContinue) -eq $holder) {
      Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
      continue
    }
    Start-Sleep -Milliseconds 100
  }
  Fail "another desktop_compact run holds $lock; remove it if no launch is in progress"
}
function Release-Lock { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }

function Stop-Watchdog {
  $pidFile = Join-Path $state 'watchdog.pid'
  if (-not (Test-Path -LiteralPath $pidFile)) { return }
  $wpid = [int]([IO.File]::ReadAllText($pidFile))
  if ($wpid -eq $PID) { return }
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $wpid" -ErrorAction SilentlyContinue
  if ($null -eq $proc -or $proc.CommandLine -notlike '*desktop_compact.ps1*') { return }
  Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue
}

function Restore-Locked {
  if (-not (Test-Path -LiteralPath $state)) { return $true }
  $writtenFile = Join-Path $state 'written.sha'
  $backup = Join-Path $state 'backup'
  $untouched = (-not (Test-Path -LiteralPath $writtenFile)) -or ((Test-Path -LiteralPath $settings) -and
    (Get-Sha $settings) -eq [IO.File]::ReadAllText($writtenFile))
  if ($untouched) {
    if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $settings -Force }
    else { Remove-Item -LiteralPath $settings -Force -ErrorAction SilentlyContinue }
  } elseif (Test-Path -LiteralPath $settings) {
    try { Json-Key $settings ([IO.File]::ReadAllText((Join-Path $state 'previous'))) | Out-Null } catch { return $false }
  }
  if (Test-Path -LiteralPath (Join-Path $state 'created_claude_dir')) {
    $claudeDir = Join-Path $dir '.claude'
    if (@(Get-ChildItem -LiteralPath $claudeDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
      Remove-Item -LiteralPath $claudeDir -Force -ErrorAction SilentlyContinue
    }
  }
  Stop-Watchdog
  Remove-Item -LiteralPath $state -Recurse -Force
  return $true
}

if ($cmd -eq 'restore' -and $after -gt 0) { Start-Sleep -Seconds $after }
Acquire-Lock
try {
  if ($cmd -eq 'restore') {
    if (-not (Test-Path -LiteralPath $state)) { "nothing to restore for $dir"; exit 0 }
    if (-not (Restore-Locked)) { Fail "could not revert autoCompactWindow in $settings (not a JSON object); state kept in $state" }
    "autocompact setting reverted for $dir"
    exit 0
  }

  $value = Normalize-Autocompact $autocompact
  if ($null -eq $value) { Fail "invalid --autocompact: $autocompact (auto, or 100k to 1M)" }
  # Restore a state left by an earlier run first, so our own key is never backed up as the user setting.
  if (-not (Restore-Locked)) { Fail "a previous run's change to $settings could not be reverted (not a JSON object); state kept in $state" }
  if ($value -eq 'auto') { 'autocompact auto: settings left unchanged'; exit 0 }
  if ((Test-Path -LiteralPath $settings) -and
      ((Get-Item -LiteralPath $settings -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Fail "$settings is a link; not changing it"
  }

  $staging = "$state.new"
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $staging | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $dir '.claude'))) { Put (Join-Path $staging 'created_claude_dir') '' }
  if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination (Join-Path $staging 'backup') }
  try { $previous = Json-Key $settings } catch {
    Remove-Item -LiteralPath $staging -Recurse -Force
    Fail "$settings is not a JSON object; not changing it"
  }
  Put (Join-Path $staging 'previous') $previous
  Move-Item -LiteralPath $staging -Destination $state

  New-Item -ItemType Directory -Force -Path (Join-Path $dir '.claude') | Out-Null
  try { Json-Key $settings $value | Out-Null } catch {
    Restore-Locked | Out-Null
    Fail "could not update $settings"
  }
  Put (Join-Path $state 'written.sha') (Get-Sha $settings)

  $self = $MyInvocation.MyCommand.Path
  # the current host, never powershell by name: a 5.1 child of pwsh 7 cannot load Get-FileHash
  $watchdog = Start-Process (Get-Process -Id $PID).Path -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", 'restore', '--dir', "`"$dir`"", '--after', $timeout)
  Put (Join-Path $state 'watchdog.pid') ([string]$watchdog.Id)
  "autocompact $value set in $settings; restore once the worker has started (list_events shows its first message), or it restores itself in ${timeout}s"
} finally {
  Release-Lock
}
