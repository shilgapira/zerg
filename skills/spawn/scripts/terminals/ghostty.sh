open_tab() {
  local tag="spawn-$$-$RANDOM" found="" window_id shown_tab bounds prior_app prior="" new_term="" title prefix rc=1

  # Phase 1: find the caller window through a title tag
  for _ in 1 2 3 4 5; do
    printf '\033]2;%s\007' "$tag" > "$caller_tty" || break
    sleep 0.2
    found="$(osascript - "$tag" <<'APPLESCRIPT'
on run argv
  set tag to item 1 of argv
  set winId to ""
  set shownId to ""
  set winIndex to 0
  tell application "Ghostty"
    set i to 0
    repeat with w in windows
      set i to i + 1
      repeat with t in tabs of w
        repeat with s in terminals of t
          if name of s contains tag then
            set winId to id of w
            set shownId to id of selected tab of w
            set winIndex to i
          end if
        end repeat
      end repeat
      if winId is not "" then exit repeat
    end repeat
    set winCount to count of windows
  end tell
  if winId is "" then error "No Ghostty terminal carries the title tag"
  return winId & linefeed & shownId & linefeed & winIndex & linefeed & winCount
end run
APPLESCRIPT
)" && { rc=0; break; }
  done
  # an empty title is fine: Claude Code sets its own again on its next update
  printf '\033]2;\007' > "$caller_tty" 2>/dev/null || true
  [ "$rc" = 0 ] || return 1
  window_id="$(printf '%s\n' "$found" | sed -n 1p)"
  shown_tab="$(printf '%s\n' "$found" | sed -n 2p)"
  bounds="$(window_bounds_by_order Ghostty "$(printf '%s\n' "$found" | sed -n 3p)" \
    "$(printf '%s\n' "$found" | sed -n 4p)")"

  # shellcheck disable=SC2086
  shield_start "$name" Ghostty $bounds

  # Phase 2: record what the user is looking at as late as possible, then open the tab
  prior_app="$(front_app)"
  if [ "$prior_app" = com.mitchellh.ghostty ]; then
    prior="$(osascript -e 'tell application "Ghostty"' \
      -e 'return (id of front window) & linefeed & (id of selected tab of front window)' \
      -e 'end tell' 2>/dev/null || true)"
  fi
  new_term="$(osascript - "$window_id" <<'APPLESCRIPT'
on run argv
  tell application "Ghostty"
    set newTab to new tab in window id (item 1 of argv)
    return id of focused terminal of newTab
  end tell
end run
APPLESCRIPT
)" || rc=1

  if [ "$rc" = 0 ]; then
    shield_refocus

    # Phase 3: type Ctrl-U (clears any stray input) plus the command
    osascript - "$new_term" "$tab_command" <<'APPLESCRIPT' || rc=1
on run argv
  tell application "Ghostty"
    set t to terminal id (item 1 of argv)
    send key "u" modifiers "control" to t
    input text (item 2 of argv) to t
    send key "enter" to t
  end tell
end run
APPLESCRIPT
  fi
  if [ "$rc" = 0 ]; then
    shield_launching
    for _ in $(seq 1 50); do
      title="$(osascript -e "tell application \"Ghostty\" to return name of terminal id \"$new_term\"" \
        2>/dev/null || true)"
      prefix="${title%" $name"}"
      [ "$prefix" != "$title" ] && [[ "$prefix" != */* ]] && break
      shield_running || break
      sleep 0.1
    done
    shield_restoring
  else
    shield_abort
  fi

  # Phase 4: put the user back where they were
  osascript - "$window_id" "$shown_tab" \
    "$(printf '%s\n' "$prior" | sed -n 1p)" "$(printf '%s\n' "$prior" | sed -n 2p)" \
    <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  tell application "Ghostty"
    select tab (tab id (item 2 of argv) of window id (item 1 of argv))
    if item 3 of argv is not "" then
      activate window (window id (item 3 of argv))
      select tab (tab id (item 4 of argv) of window id (item 3 of argv))
    end if
  end tell
end run
APPLESCRIPT
  activate_app "$prior_app" com.mitchellh.ghostty
  shield_finish
  return $rc
}
