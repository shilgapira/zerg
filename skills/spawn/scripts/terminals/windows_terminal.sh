open_tab() {
  local shell launcher_ps1 job title semicolon
  shell="$(command -v pwsh.exe || command -v powershell.exe)" || return 1
  shell="$(cygpath -w "$shell")"
  launcher_ps1="$(cygpath -w "$here/lib/wt_launcher.ps1")"
  job="$(cygpath -w "$launcher")"
  case "$shell$launcher_ps1$job" in
    *';'*) echo "spawn: a path contains ';', which Windows Terminal cannot take" >&2; return 1 ;;
  esac
  if ! "$shell" -NoLogo -Command 'if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 1 }'; then
    echo "spawn: claude is not on PATH for $shell, so a new tab could not start it" >&2
    return 1
  fi
  # from a variable: bash 5.2 turns a backslash-semicolon written in the expansion into a bare semicolon
  semicolon='\;'
  title="${name//;/$semicolon}"
  MSYS_NO_PATHCONV=1 wt.exe -w 0 new-tab --title "$title" -d "$(cygpath -w "$dir")" \
    "$shell" -NoExit -ExecutionPolicy Bypass -File "$launcher_ps1" -Job "$job"
}
