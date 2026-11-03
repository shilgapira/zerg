# Windows counterpart of desktop_compact_test.sh, on throwaway folders (never a real project). Run with:
# powershell -NoProfile -ExecutionPolicy Bypass -File tests\desktop_compact_test.ps1
$ErrorActionPreference = 'Continue'
$dc = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\desktop_compact.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("dc-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$ps = (Get-Process -Id $PID).Path
$script:pass = 0; $script:fail = 0
$utf8 = New-Object Text.UTF8Encoding $false

function Ok($got, $expected, $label) {
  if ("$got" -eq "$expected") { $script:pass++; "  ok   $label" }
  else { $script:fail++; "  FAIL $label`: expected [$expected] got [$got]" }
}
function Dc { & $ps -NoProfile -ExecutionPolicy Bypass -File $dc @args 2>$null; $script:code = $LASTEXITCODE }
function SettingsOf($d) { Join-Path $d '.claude\settings.local.json' }
function Key($d) {
  $f = SettingsOf $d
  if (-not (Test-Path -LiteralPath $f)) { return 'nofile' }
  $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json
  if ($null -ne $o.PSObject.Properties['autoCompactWindow']) { return [string]$o.autoCompactWindow } else { return 'none' }
}
function Sha($d) { (Get-FileHash -Algorithm SHA256 -LiteralPath (SettingsOf $d)).Hash }
function NewDir($name, [switch]$WithSettings, [string]$Content) {
  $d = Join-Path $root $name
  New-Item -ItemType Directory -Path $d | Out-Null
  if ($WithSettings) {
    New-Item -ItemType Directory -Path (Join-Path $d '.claude') | Out-Null
    [IO.File]::WriteAllText((SettingsOf $d), $Content, $utf8)
  }
  return (& $ps -NoProfile -ExecutionPolicy Bypass -File $dc path --dir $d)
}
function StateDir($d) {
  $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($d))).Replace('-', '')
  Join-Path ([IO.Path]::GetTempPath()) ("claude-spawn\compact-" + $h.Substring(0, 16).ToLowerInvariant())
}
$orig = "{`n  `"permissions`": {`"allow`": [`"Bash(ls:*)`"]},`n  `"nested`": {`"a`": {`"b`": {`"c`": [1, {`"d`": `"x`"}]}}}`n}`n"

"1. no settings file, no .claude dir"
$d = NewDir 't1'
Dc set --dir $d --autocompact 500k | Out-Null; Ok (Key $d) 500000 'key set'
Dc restore --dir $d | Out-Null; Ok (Test-Path -LiteralPath (Join-Path $d '.claude')) $false 'file and .claude removed'

"2. existing file, untouched meanwhile: byte-exact restore"
$d = NewDir 't2' -WithSettings -Content $orig; $before = Sha $d
Dc set --dir $d --autocompact 450k | Out-Null; Ok (Key $d) 450000 'key set to 450k'
Ok ([IO.File]::ReadAllText((SettingsOf $d)).Contains('Bash(ls:*)')) $true 'other keys kept'
Ok ([IO.File]::ReadAllText((SettingsOf $d)).Contains('"d"')) $true 'nested object kept (not flattened)'
Dc restore --dir $d | Out-Null; Ok (Sha $d) $before 'byte-exact restore'

"3. file changed meanwhile: only our key reverted"
$d = NewDir 't3' -WithSettings -Content $orig
Dc set --dir $d --autocompact 500k | Out-Null
$o = [IO.File]::ReadAllText((SettingsOf $d)) | ConvertFrom-Json; $o | Add-Member -NotePropertyName extra -NotePropertyValue 1
[IO.File]::WriteAllText((SettingsOf $d), (ConvertTo-Json $o -Depth 100), $utf8)
Dc restore --dir $d | Out-Null; Ok (Key $d) none 'our key removed'
Ok ([IO.File]::ReadAllText((SettingsOf $d)).Contains('"extra"')) $true 'concurrent change kept'

"4. user already had a value, file changed meanwhile: original value back"
$d = NewDir 't4' -WithSettings -Content "{`"autoCompactWindow`": 300000}`n"
Dc set --dir $d --autocompact 500k | Out-Null; Ok (Key $d) 500000 'overridden to 500k'
$o = [IO.File]::ReadAllText((SettingsOf $d)) | ConvertFrom-Json; $o | Add-Member -NotePropertyName extra -NotePropertyValue 1
[IO.File]::WriteAllText((SettingsOf $d), (ConvertTo-Json $o -Depth 100), $utf8)
Dc restore --dir $d | Out-Null; Ok (Key $d) 300000 'original 300000 back'

"5. stale state from a run that never restored"
$d = NewDir 't5' -WithSettings -Content $orig; $before = Sha $d
Dc set --dir $d --autocompact 400k | Out-Null; Dc set --dir $d --autocompact 600k | Out-Null; Ok (Key $d) 600000 'second set wins'
Dc restore --dir $d | Out-Null; Ok (Sha $d) $before 'user original back'

"6. watchdog restores after the timeout"
$d = NewDir 't6' -WithSettings -Content $orig; $before = Sha $d
$env:SPAWN_COMPACT_TIMEOUT = '3'; Dc set --dir $d --autocompact 500k | Out-Null; Remove-Item Env:SPAWN_COMPACT_TIMEOUT
Start-Sleep -Seconds 8; Ok (Sha $d) $before 'restored by watchdog'

"7. explicit restore stops the watchdog"
$d = NewDir 't7'
$env:SPAWN_COMPACT_TIMEOUT = '60'; Dc set --dir $d --autocompact 500k | Out-Null; Remove-Item Env:SPAWN_COMPACT_TIMEOUT
$wpid = [int][IO.File]::ReadAllText((Join-Path (StateDir $d) 'watchdog.pid'))
Dc restore --dir $d | Out-Null; Start-Sleep -Milliseconds 500
Ok ($null -ne (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) $false 'watchdog stopped'

"8. invalid JSON is left untouched"
$d = NewDir 't8' -WithSettings -Content "{broken`n"
Dc set --dir $d --autocompact 500k | Out-Null; Ok $script:code 1 'set fails'
Ok ([IO.File]::ReadAllText((SettingsOf $d))) "{broken`n" 'file unchanged'

"9. auto, defaults and bad values"
$d = NewDir 't9'
Ok (Dc set --dir $d --autocompact auto) 'autocompact auto: settings left unchanged' 'auto leaves settings'
Ok (Dc set --dir $d) 'autocompact auto: settings left unchanged' 'no value means auto'
Ok (Test-Path -LiteralPath (Join-Path $d '.claude')) $false 'nothing created for auto'
Dc set --dir $d --autocompact 50k | Out-Null; Ok $script:code 1 '50k rejected'
Ok @(Dc set --dir $d --autocompact 200)[0].StartsWith('autocompact 200000') $true '200 means 200k'
Dc restore --dir $d | Out-Null
Ok ((Dc protocol --report-to 'Orch').Substring(0, 60)) 'You are a worker session started by the Claude Code session ' 'protocol text'

"10. canonical path"
$d = NewDir 't10'
Ok (Dc path --dir $d.ToLowerInvariant()) $d 'lowercase input gives the true case'
Ok (Dc path --dir ($d.Replace('\', '/') + '/')) $d 'forward slashes and trailing slash normalized'

"11. crash after the write, before the hash was recorded: exact backup restored"
$d = NewDir 't11' -WithSettings -Content $orig; $before = Sha $d
$env:SPAWN_COMPACT_TIMEOUT = '60'; Dc set --dir $d --autocompact 500k | Out-Null; Remove-Item Env:SPAWN_COMPACT_TIMEOUT
Remove-Item -LiteralPath (Join-Path (StateDir $d) 'written.sha')
Dc restore --dir $d | Out-Null; Ok (Sha $d) $before 'backup restored'
Ok (Test-Path -LiteralPath (StateDir $d)) $false 'state dropped'

"12. file left as invalid JSON by someone else: restore keeps the state and says so"
$d = NewDir 't12' -WithSettings -Content $orig
$env:SPAWN_COMPACT_TIMEOUT = '60'; Dc set --dir $d --autocompact 500k | Out-Null; Remove-Item Env:SPAWN_COMPACT_TIMEOUT
[IO.File]::WriteAllText((SettingsOf $d), "{broken`n", $utf8)
Dc restore --dir $d | Out-Null; Ok $script:code 1 'restore fails'
Ok (Test-Path -LiteralPath (StateDir $d)) $true 'state kept'
Dc set --dir $d --autocompact 500k | Out-Null; Ok $script:code 1 'next set refuses'
[IO.File]::WriteAllText((SettingsOf $d), $orig, $utf8); Dc restore --dir $d | Out-Null; Ok $script:code 0 'restore works once valid'

"13. a non-numeric timeout is rejected"
$d = NewDir 't13'
$env:SPAWN_COMPACT_TIMEOUT = 'abc'; Dc set --dir $d --autocompact 500k | Out-Null; Remove-Item Env:SPAWN_COMPACT_TIMEOUT
Ok $script:code 1 'set fails'; Ok (Test-Path -LiteralPath (Join-Path $d '.claude')) $false 'nothing written'

"14. a lock left by a killed run is taken over"
$d = NewDir 't14'
$p = Start-Process cmd -ArgumentList '/c', 'exit' -WindowStyle Hidden -PassThru; $p.WaitForExit()
New-Item -ItemType Directory -Path ((StateDir $d) + '.lock') | Out-Null
[IO.File]::WriteAllText((Join-Path ((StateDir $d) + '.lock') 'pid'), "$($p.Id)", $utf8)
Dc set --dir $d --autocompact 500k | Out-Null; Ok $script:code 0 'set takes the lock over'
Dc restore --dir $d | Out-Null; Ok (Test-Path -LiteralPath ((StateDir $d) + '.lock')) $false 'lock released'

"== $script:pass passed, $script:fail failed"
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
