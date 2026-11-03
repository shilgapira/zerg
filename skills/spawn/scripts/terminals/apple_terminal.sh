open_tab() {
  local found window_id bounds prior="" prior_app="" prior_tty="" shown_tty new_tty="" existing rc=0

  # Phase 1 (read-only): locate the caller window and the ttys that exist before the new tab
  found="$(osascript - "$caller_tty" <<'APPLESCRIPT'
-- The session part of a title like "dir - <glyph> Session - proc", minus the animated glyph.
on titleKey(n)
  set text item delimiters to " " & (character id 8212) & " "
  set parts to text items of n
  set text item delimiters to ""
  if (count of parts) < 2 then return n
  set s to item 2 of parts
  if (length of s) > 2 and character 2 of s is " " then set s to text 3 thru -1 of s
  return s
end titleKey

on run argv
  set callerTty to item 1 of argv
  tell application "Terminal"
    set targetWindow to missing value
    repeat with w in windows
      try
        repeat with t in tabs of w
          if tty of t is callerTty then set targetWindow to contents of w
        end repeat
      end try
      if targetWindow is not missing value then exit repeat
    end repeat
    if targetWindow is missing value then error "No Terminal tab has tty " & callerTty
    set b to bounds of targetWindow
  end tell

  set shownKey to ""
  tell application "System Events" to tell process "Terminal"
    repeat with w in windows
      try
        set p to position of w
        if (item 1 of p) = (item 1 of b) and (item 2 of p) = (item 2 of b) then
          set shownKey to my titleKey(name of w)
          exit repeat
        end if
      end try
    end repeat
  end tell

  tell application "Terminal"
    set shownTty to callerTty
    if shownKey is not "" then
      repeat with w in windows
        try
          if (bounds of w) = b and my titleKey(name of w) = shownKey then
            set shownTty to tty of tab 1 of w
            exit repeat
          end if
        end try
      end repeat
    end if
    set boundsText to ((item 1 of b) as text) & " " & (item 2 of b) & " " & (item 3 of b) & " " & (item 4 of b)
    set out to {(id of targetWindow) as text, boundsText, shownTty}
    -- live tabs only: a dead tab keeps its old tty, which macOS reuses for the new tab
    repeat with w in windows
      try
        repeat with t in tabs of w
          if (processes of t) is not {} then set end of out to tty of t
        end repeat
      end try
    end repeat
  end tell
  set text item delimiters to linefeed
  return out as text
end run
APPLESCRIPT
)" || return 1
  window_id="$(printf '%s\n' "$found" | sed -n 1p)"
  bounds="$(printf '%s\n' "$found" | sed -n 2p)"
  shown_tty="$(printf '%s\n' "$found" | sed -n 3p)"
  existing="$(printf '%s\n' "$found" | sed -n '4,$p')"

  # shellcheck disable=SC2086
  shield_start "$name" Terminal $bounds

  # Phase 2: record what the user is looking at as late as possible, then raise the caller tab and activate Terminal
  prior="$(osascript - "$caller_tty" "$window_id" <<'APPLESCRIPT'
on run argv
  set callerTty to item 1 of argv
  set windowId to (item 2 of argv) as integer
  set priorApp to ""
  set priorTty to ""
  tell application "System Events"
    try
      set priorApp to bundle identifier of first process whose frontmost is true
    end try
  end tell
  tell application "Terminal"
    try
      set priorTty to tty of selected tab of front window
    end try
  end tell
  tell application "Terminal"
    set w to window id windowId
    repeat with t in tabs of w
      if tty of t is callerTty then set selected of t to true
    end repeat
    set index of w to 1
    activate
  end tell
  tell application "System Events" to tell process "Terminal"
    repeat 50 times
      if frontmost then exit repeat
      delay 0.1
    end repeat
    if not frontmost then error "Terminal did not come to the front"
  end tell
  tell application "Terminal"
    if id of front window is not windowId then error "The calling window is not the front Terminal window"
  end tell
  return priorApp & linefeed & priorTty
end run
APPLESCRIPT
)" || rc=1
  prior_app="$(printf '%s\n' "$prior" | sed -n 1p)"
  prior_tty="$(printf '%s\n' "$prior" | sed -n 2p)"

  if [ "$rc" = 0 ]; then
    shield_refocus

    # Phase 3: press New Tab, find the tab with a new tty, type Ctrl-U (clears any stray input) plus the command
    new_tty="$(osascript - "$tab_command" "$existing" <<'APPLESCRIPT'
on run argv
  set tabCommand to item 1 of argv
  set existingTtys to paragraphs of item 2 of argv
  tell application "System Events" to tell process "Terminal"
    try
      set newTabItem to menu item 1 of menu 1 of menu item "New Tab" of menu "Shell" of menu bar 1
    on error
      error "Terminal menu item Shell > New Tab not found (non-English UI?)"
    end try
    click newTabItem
  end tell

  tell application "Terminal"
    set newTab to missing value
    repeat 50 times
      repeat with w in windows
        try
          repeat with t in tabs of w
            if tty of t is not in existingTtys and (processes of t) is not {} then
              set newTab to contents of t
            end if
          end repeat
        end try
        if newTab is not missing value then exit repeat
      end repeat
      if newTab is not missing value then exit repeat
      delay 0.1
    end repeat
    if newTab is missing value then error "Shell > New Tab did not open a new tab"
    do script ((character id 21) & tabCommand) in newTab
    return tty of newTab
  end tell
end run
APPLESCRIPT
)" || rc=1
  fi

  if [ "$rc" = 0 ]; then
    shield_launching
    for _ in $(seq 1 50); do
      ps -t "${new_tty#/dev/}" -o comm= 2>/dev/null | grep -qE '(^|/)claude$' && break
      shield_running || break
      sleep 0.1
    done
    shield_restoring
  else
    shield_abort
  fi

  # Phase 4: put the user back where they were
  osascript - "$shown_tty" "$prior_tty" "$prior_app" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on selectTty(wanted)
  if wanted is "" then return
  tell application "Terminal"
    repeat with w in windows
      try
        repeat with t in tabs of w
          if tty of t is wanted then
            set selected of t to true
            set index of w to 1
            return
          end if
        end repeat
      end try
    end repeat
  end tell
end selectTty

on run argv
  set shownTty to item 1 of argv
  set priorTty to item 2 of argv
  set priorApp to item 3 of argv
  selectTty(shownTty)
  if priorTty is not shownTty then selectTty(priorTty)
  if priorApp is not "" and priorApp is not "com.apple.Terminal" then tell application id priorApp to activate
end run
APPLESCRIPT

  shield_finish
  return $rc
}
