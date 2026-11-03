open_tab() {
  osascript - "$caller_tty" "$tab_command" <<'APPLESCRIPT'
on run argv
  set callerTty to item 1 of argv
  set tabCommand to item 2 of argv
  tell application "iTerm2"
    set targetId to missing value
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          set sTty to ""
          try
            set sTty to tty of s
          end try
          if sTty is callerTty then
            set targetId to id of w
            set callerProfile to profile name of s
          end if
        end repeat
      end repeat
      if targetId is not missing value then exit repeat
    end repeat
    if targetId is missing value then error "No iTerm2 session has tty " & callerTty

    set shownSession to id of current session of current tab of window id targetId

    -- a profile renamed or deleted since the caller started still reports its old name, hence the fallback
    tell window id targetId
      try
        set newTab to (create tab with profile callerProfile)
      on error
        set newTab to (create tab with default profile)
      end try
    end tell
    tell current session of newTab to write text tabCommand

    -- selecting a tab does not bring iTerm2 to the front
    repeat with t in tabs of window id targetId
      repeat with s in sessions of t
        if id of s is shownSession then tell t to select
      end repeat
    end repeat
    return
  end tell
end run
APPLESCRIPT
}
