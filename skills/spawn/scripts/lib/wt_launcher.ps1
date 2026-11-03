param([Parameter(Mandatory = $true)][string]$Job)
$utf8 = New-Object Text.UTF8Encoding $false
function Read-Job([string]$file) {
  $path = Join-Path $Job $file
  if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path, $utf8) }
  return ''
}
function Native-Arg([string]$value) {
  if (-not $legacyPassing) { return $value }
  $value = [regex]::Replace($value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
  if ($value -match '\s') { $value = [regex]::Replace($value, '(\\+)$', { param($m) $m.Groups[1].Value * 2 }) }
  return $value
}
$name = Read-Job 'name.txt'; $dir = Read-Job 'dir.txt'; $mode = Read-Job 'mode.txt'
$autocompact = Read-Job 'autocompact.txt'; $system = Read-Job 'system.txt'; $prompt = Read-Job 'prompt.txt'
Remove-Item -LiteralPath $Job -Recurse -Force -ErrorAction SilentlyContinue
Clear-Host
$esc = [char]27
Write-Host ''
Write-Host 'New agent session:'
Write-Host "$esc[1m$name$esc[0m"
Write-Host ''
# Set by a terminal first started inside a Claude session; a worker with them is a child, unreachable by name.
foreach ($var in 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDECODE', 'CLAUDE_CODE_SSE_PORT') {
  Remove-Item -LiteralPath "Env:$var" -ErrorAction SilentlyContinue
}
Set-Location -LiteralPath $dir
$claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) {
  Write-Host "spawn: claude is not on PATH in this tab, so the session could not start" -ForegroundColor Red
  return
}
$legacyPassing = -not ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy')
$arguments = @('-n', (Native-Arg $name), '--permission-mode', $mode)
if ($autocompact) { $arguments += @('--autocompact', $autocompact) }
if ($system) { $arguments += @('--append-system-prompt', (Native-Arg $system)) }
$arguments += (Native-Arg $prompt)
& $claude @arguments
