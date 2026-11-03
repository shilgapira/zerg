# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this folder.

`spawn` is the zerg plugin's `/zerg:spawn` skill: `SKILL.md` is a short router that sends calling sessions to
`references/terminal.md` or `references/claude-desktop.md`, and `scripts/` opens a new tab in the caller's terminal
window and starts a named `claude` session in it. Everything must run on a stock Mac with no Xcode, Python, Ruby or
Homebrew, so only bash, AppleScript (`osascript`) and JXA (`osascript -l JavaScript`); on Windows, only Git Bash (which
the Claude Code CLI requires there) and Windows PowerShell 5.1 or pwsh.

## Checking changes

The Makefile wraps the checks and the test:

```bash
make check     # bash -n per script, osacompile of every AppleScript heredoc, osacompile -l JavaScript of the JXA
make dry-run   # terminal and tty detection plus the generated launcher; never runs a terminals/*.sh script
make test      # tests/launcher_test.sh (the launcher under /bin/bash and zsh), then tests/desktop_compact_test.sh
make clean     # remove leftover launchers and shield state dirs from $TMPDIR/claude-spawn
```

A real test is a launch: `scripts/launch.sh --name "Spawn: Smoke Test" --prompt-file <file> --report-to
"<your session name>"`, then confirm the tab joined the caller's window, the worker shows in ListAgents and
its check-in arrives. Clean up by typing Ctrl-U plus `/exit` into the worker with `do script`, then `exit` into its
shell, then closing the tab: a tab whose shell exited stays open as "[Process completed]" and keeps its old tty (see
Traps). Terminal.app, iTerm2, Ghostty and tmux 3.8 have been tested end to end. For tmux, drive a scratch session
from outside with `tmux send-keys` and read it with `tmux capture-pane -p`. Windows Terminal can only be tested on
Windows (see Windows); `make check` and `make dry-run` here never parse or run `wt_launcher.ps1`.

To test another terminal from here, make one of its shells the caller: create a scratch window through its
AppleScript, `cd` it into a project (a worker started in the home folder stops at Claude Code's folder-trust
prompt), and type the `launch.sh` command into it (iTerm2: `write text`; Ghostty: `input text` then
`send key "enter"`). Clean up by typing `exit` into every scratch shell so the window closes by itself; closing a
window with live shells shows a confirmation dialog that blocks the AppleScript call until the user answers.

Processes started from the Bash tool never receive the user's real keyboard or mouse input, so anything about
input blocking needs the user to type while the test runs, or to run it themselves with `!`.

## Architecture

`launch.sh` validates arguments, finds the caller's tty by walking up the process tree (the Bash tool subprocess
has none), picks a terminal (Windows Terminal on Git Bash first, then `$TMUX`, then `TERM_PROGRAM`; anything else
is a hard error) and writes a launcher to `$TMPDIR/claude-spawn/` (without `TMPDIR`, as usual on Linux, to
`/tmp/claude-spawn-<uid>/`, mode 700 and refused unless the user owns it; on Windows a job folder instead; see
Windows). The launcher is one brace group: it deletes itself, clears the screen,
prints a banner (the name is a printf argument, never part of the format; names with control characters are
rejected up front), `cd`s, and runs `claude -n <name> --permission-mode <mode> --autocompact <tokens>` with the
prompt embedded as a quoted heredoc. The mode defaults to `auto`, since workers run unattended. With `--report-to`,
the report-back protocol goes in `--append-system-prompt` rather than the kickoff, because the system prompt
survives compaction. `--autocompact` defaults to `auto`, which passes no flag so the user's settings apply; a value
is validated and normalized (to a plain token count) before any tab opens, using the same rule as the CLI. The new
tab's interactive shell sources the launcher (`. launcher`) rather than executing it, because `claude` may be a
shell function. `launch.sh` then sources `scripts/terminals/<terminal>.sh` under `set -euo pipefail`, which must
define `open_tab`, reading `name`, `dir`, `caller_tty`, `tab_command` (unset on Windows), `launcher`, `here` and
`launcher_dir` and returning non-zero on failure. `scripts/lib/shield.sh`
is sourced first and gives terminal scripts the panel lifecycle (`shield_start`, `shield_refocus`,
`shield_launching`, `shield_running`, `shield_restoring`, `shield_abort`, `shield_finish`) plus `front_app`,
`activate_app`, `window_bounds_by_order` and `wait_for`; use it for any terminal that comes to the front when it
opens a tab.

Adding a terminal means one new `scripts/terminals/<name>.sh` plus one `case` line in `launch.sh`. Every launch
leaves the user where they were: the tab the caller's window showed, their selected tab and their frontmost app,
whether or not the caller's tab was the selected one.

| Detected by | Script | Mechanism |
|---|---|---|
| `$TMUX` set (checked first) | `tmux.sh` | `tmux new-window -d` after the caller's window, then `send-keys`; the caller's window stays active |
| `TERM_PROGRAM=Apple_Terminal` | `apple_terminal.sh` | Menu press of Shell > New Tab behind the panel, `do script` |
| `TERM_PROGRAM=iTerm.app` | `iterm.sh` | `create tab` and `write text`, in the background |
| `TERM_PROGRAM=ghostty` | `ghostty.sh` | `new tab` (Ghostty 1.3+ AppleScript) behind the panel, `input text` |
| Git Bash (`uname` MINGW) with `WT_SESSION` set | `windows_terminal.sh` | `wt.exe -w 0 new-tab` running `lib/wt_launcher.ps1` on a job folder; focus moves to the new tab |

All AppleScript terminals need Automation permission on first use.

`apple_terminal.sh` runs in phases. Terminal.app has no "new tab" AppleScript command, so it presses the menu
item through System Events, which needs Accessibility permission and only works with an English menu bar; pressing
the item rather than sending Cmd-T means held modifiers cannot change what is triggered.
1. Read-only: caller window id and bounds, the tab the caller's window shows, and every existing tty. The shown tab
   is found by matching Accessibility window titles (one per tab group, titled after its visible tab) on their
   session part, since Claude Code animates a glyph in its titles; when nothing matches, the caller's tab is used.
2. `shield_start`: show the panel, wait up to 2s for it, then 1s more. Record the frontmost app and selected
   tab, raise the caller's window and activate Terminal. Activation takes keyboard focus from the panel, so the
   script touches `focus` and waits for `ready` before typing anything.
3. Press Shell > New Tab > its first item (the default profile) through System Events, find the tab with a new
   tty, `do script` Ctrl-U plus the launcher command (`shield_launching`), then wait until `claude` shows in
   `ps -t <tty>` (`shield_restoring`).
4. While the panel says "Restoring focus...", restore the shown tab, the selected tab and the frontmost app, then
   `shield_finish`.

`ghostty.sh` follows the same shape. Ghostty exposes no tty, so phase 1 writes an OSC title tag to the caller's
tty and finds the terminal whose name carries it, retrying because Claude Code can overwrite the tag, then clears
the title. `new tab` activates Ghostty, so the panel is refocused before Ctrl-U and the command go in through
`send key` and `input text`. The launch counts as done once the new terminal's title is Claude Code's: a prefix
without a "/" (the status glyph), a space and the session name, which shell-set titles such as the launcher
command or a path never are. The panel is centered on the caller's window without any permission:
`window_bounds_by_order` (lib/shield.sh) takes the window's index in Ghostty's AppleScript window list, which runs
front to back, and reads the bounds of the same index from the CoreGraphics on-screen window list. When the two
lists differ in length (windows on other Spaces or minimized), the panel centers on the screen. Phase 4 restores
the tab the caller's window showed, then the previously selected Ghostty tab or the previously frontmost app.

`iterm.sh` needs none of this: iTerm2 creates the tab and types the command without coming to the front. It opens
the tab with the caller's profile (another profile's startup command would otherwise receive the text), falling
back to the default profile if that fails, and reselects the tab the window showed before.

`scripts/lib/worker.sh` holds what terminal and Desktop launches share: `normalize_autocompact` (the CLI's
`--autocompact` rule) and `report_protocol` (the report-back text).

## Claude Desktop

A Claude Desktop session (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`, no tty) cannot open terminal tabs, and its
Bash commands run under a versioned CLI bundle (`~/Library/Application Support/Claude/claude-code/<ver>/<hash>/
claude.app`), which is the app macOS permission prompts name; grants may not survive CLI updates. So Desktop
callers do not use `launch.sh` (it refuses, pointing at references/claude-desktop.md) or any UI scripting; that
reference tells them to use Desktop's own tools. SKILL.md routes them there, and the refusal
(checked before argument parsing, so even `--dry-run` gets it) routes a Desktop caller that runs the script anyway.
The two references each carry a full conventions list; most entries are shared word for word, so change both together.
Facts established with a probe session in Desktop:
- `start_session` takes `title` (the exact ListAgents name), `prompt`, `cwd` (real path; a symlinked spelling is
  refused; for an untrusted folder the call waits on the user's trust dialog, and Cancel returns an error with
  nothing started; on Mac and Windows), `permission_mode` (at most the caller's), `model`
  and `effort` (no higher than the caller's), `context` fresh or fork, `use_worktree`, `preset`, and more, but no
  system prompt, settings, env or auto-compact option.
- Sessions start as linked children: nested in the sidebar, archived with the parent in some cases, and the parent
  gets a ~1-1.5 KB note after every worker turn, which starts a parent turn when the parent is idle.
  `detach_session` makes the worker a top-level sibling with no notes; SendMessage still reaches it. Detaching is
  refused when the worker shares a Desktop-made worktree with the parent.
- Sessions read `autoCompactWindow` once, at startup (before their transcript file exists, about 1.5s after
  `start_session` returns), and never re-read it. The folder's `.claude/settings.local.json` overrides
  `~/.claude/settings.json`; the env var, `--autocompact` and `--settings` override both but cannot be passed.
  Slash commands sent by SendMessage arrive as plain text.

`scripts/desktop_compact.sh` uses that: `set` merges `autoCompactWindow` into the folder's
`.claude/settings.local.json` (JXA JSON merge; created if absent) and starts a detached watchdog (`/bin/bash`);
`restore` (once the worker started, or by the watchdog after 60s, `SPAWN_COMPACT_TIMEOUT`) puts the backup back
when the file's hash is still the one we wrote, and otherwise reverts only our key to its previous value, so writes
Claude Code made meanwhile (such as "always allow" rules) survive. State lives in
`$TMPDIR/claude-spawn/compact-<hash of dir>/`, guarded by a lock dir. Everything needed to undo (backup,
previous value, whether `.claude` was created) is committed with one rename before the file is touched, and a state
without the written hash restores the exact backup, so a crash at any step loses nothing; `set` first restores a
state left by a run that never restored. A file that is no longer a JSON object makes `restore` fail and keep the
state (and `set` refuse) until it is fixed. A symlinked settings file is refused, since the atomic write would
replace the link. Known gaps, by design: any session started in that folder during the window also gets the value,
and a Claude Code write landing between the hash check and the restore (milliseconds) is lost. `make test` runs
`tests/desktop_compact_test.sh` against throwaway folders.

`lib/input_shield.js` is a non-activating titled panel (title bar hidden) that holds keyboard focus while the
terminal stays the active app, dropping key events in its hand-rolled event loop. It shows "Starting agent
session:", the session name, and a status row: "Opening new <terminal> tab...", "Launching Claude Code...",
"Restoring focus..." and finally "Done!" with a checkmark. It appears a second before anything moves; "Done!" comes
once the restore is done and "Restoring focus..." has shown for `RESTORE_MIN_SECONDS`, and the panel closes
`DONE_SECONDS` later. A failed launch closes it without "Done!". It talks to the shell through files in the state
dir `$launcher_dir/shield-<pid>`: it writes `shown` and `ready`, and reads `focus` (retake the keyboard) and
`launching`, `restoring` and `close`, which drive its status line. It caps the stages before and after restoring
itself (`WORK_MAX_SECONDS`, `RESTORE_MAX_SECONDS`), so it exits even if the launcher dies, though the state dir then
stays behind. Its window uses the system alert-panel animation to appear; animating its layer instead scales from a
corner and leaves the window shadow behind.

## Windows

On Windows, Claude Desktop uses `scripts/desktop_compact.ps1`, which is the Windows PowerShell 5.1 port of
`desktop_compact.sh` (same commands, state layout and protocol text, plus `path`, which prints a folder's canonical
spelling for `start_session`). Keep the two in sync, including `normalize_autocompact` and `report_protocol` in
`lib/worker.sh`. `make check` cannot parse PowerShell here, so test changes on Windows with
`powershell -NoProfile -ExecutionPolicy Bypass -File tests\desktop_compact_test.ps1`.

The CLI in Windows Terminal goes through `launch.sh` in Git Bash: instead of a bash launcher it writes a job folder
(one file per value: name, dir, mode, autocompact, system, prompt) and opens a tab running `lib/wt_launcher.ps1`, which
reads and deletes the job and starts `claude` with each value as one argument. The tab script refuses `;` in its paths
(`wt.exe` splits on it even inside quotes; the title escapes it as `;`) and checks first that `claude` resolves in
the target shell with the user's profile. `launch.sh` caps the job at 30000 bytes, under the 32767-character
Windows command line. Windows PowerShell 5.1 and pwsh before 7.3 pass native arguments the legacy way, so the
launcher escapes embedded quotes and the trailing backslashes of arguments with spaces itself; tested byte-exact
under 5.1 and 7.4 with quotes, `$`, `%`, `;`, `&`, backticks, backslashes and non-ASCII. Tab placement is
`wt -w 0`: the most recently focused window, not necessarily the caller's (see below).

Facts from verification sessions on Windows 11 (Claude Desktop 2.42304.2, bundled CLI 2.1.299):
- Claude Desktop behaves as on the Mac: `start_session`, `detach_session`, `list_events` and the parameters match;
  `autoCompactWindow` in the folder's `.claude\settings.local.json` is read once at startup and beats the user
  settings; the trust dialog makes `start_session` wait, and Cancel returns an error. Older Desktop builds (2.19675)
  lack `start_session`, and a session keeps the tool list it started with. `start_session` refuses any `cwd` but the
  exact canonical spelling (uppercase drive, backslashes, true case, long names; a trailing backslash is fine), and
  `Resolve-Path` does not fix case.
- `desktop_compact.ps1` targets Windows PowerShell 5.1, which every Windows install has (node and pwsh 7 are
  optional extras), and must also run under pwsh 7. ConvertTo-Json needs `-Depth 100` (5.1 silently flattens
  nested objects otherwise; with it both versions round-trip exactly, unicode included); write with
  `[IO.File]::WriteAllText` and BOM-less UTF-8, since 5.1 `Set-Content -Encoding UTF8` adds a BOM; 5.1 escapes
  `<>'&` as `<` and the like, which is valid JSON and only touches the key-only revert path. `Get-FileHash`
  gives the sha. A detached watchdog (`Start-Process <exe> -WindowStyle Hidden`) survives the end of the tool call
  and the turn. Start children with the current host (`(Get-Process -Id $PID).Path`), never `powershell` by name:
  a 5.1 child started by pwsh 7 through `Start-Process` inherits pwsh 7's `PSModulePath` and cannot load
  `Get-FileHash` (running `powershell` as a direct native command gets the path fixed, `Start-Process` does not).
- Shells: Desktop gives PowerShell 7 (primary) and Git Bash; `bash` from PowerShell is WSL's launcher, not Git Bash;
  Git Bash rewrites slash-led arguments (`/w` becomes `W:/`) unless `MSYS_NO_PATHCONV=1`. Locally written `.ps1`
  files run under the default RemoteSigned policy.
- Windows Terminal (`wt.exe`): `wt -w 0 new-tab` targets the most recently focused window, not the caller's, and
  `WT_SESSION` identifies a tab, not a window, so a launch lands in another window if the user switched windows in
  between. A possible fix, not built: a script in the caller's tab can get its window with
  `GetParent(GetConsoleWindow())`, and `SetForegroundWindow` on it before `wt -w 0` put the tab in the caller's
  window (worked once). Unknown: whether claude.exe's tool shells share the tab's console (if not,
  `GetConsoleWindow` will not find the tab), and how reliably Windows allows the foreground switch.
- Desktop is a Store (MSIX) app: inside its process tree `%APPDATA%\Claude` is virtualized, so its bundled
  `claude.exe` lives at `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude\claude-code\<ver>\...` for
  any other process, such as a Windows Terminal tab. A Windows Terminal first started from a Claude session passes
  `CLAUDE_CODE_CHILD_SESSION` and friends to its tabs (the launcher must clear them, as `launch.sh` does).
- A CLI worker in auto mode refuses to run `wt.exe` when another session asks it to, so a caller must launch
  workers itself, on its own user's request.
- Claude Desktop does not put `claude` on PATH; a Windows Terminal tab only has it after a native CLI install
  (`~\.local\bin`). A tab whose PowerShell cannot find `claude` would sit at an error, hence the pre-check.
- The quote escaping applies whatever `claude` resolves to: npm's `claude.ps1` shim or a profile function gets its
  arguments unparsed but then calls a native program itself, under the same legacy passing. Limiting the escaping
  to a native `claude.exe` broke all 12 shim and function cases under 5.1.
- Git Bash's bash 5.2 turns a `\;` or `\\;` written inside `${name//;/...}` into a bare `;` (patsub_replacement),
  which made `wt.exe` split one tab into two; the replacement comes from a variable instead. macOS bash 3.2 behaves
  differently, so test this only on Windows.
- A tab opened by `wt.exe` from Git Bash inherits the caller's environment, PATH included, so the `claude` pre-check
  and the tab agree.

## Traps already hit

- `tmux new-window -t` takes a window, not a pane id (`can't specify pane here`); resolve `$TMUX_PANE` with
  `display-message -p '#{window_id}'`. A bad pane id there silently falls back to the current pane, so to force a
  tmux failure in a test, point `$TMUX` at a missing socket instead.
- Git Bash on Windows has a `ps` without `-o`; under `set -e` and `pipefail` the tty walk exited silently, so the
  probes end in `|| true` and Windows shells are refused by `uname` before them.
- Terminal.app with native tabs exposes every tab as its own scripting window with one tab, so tab counts per
  window never change; detect a new tab by a tty that did not exist before.
- A Terminal.app tab whose shell exited ("[Process completed]") keeps reporting its old tty, and macOS hands that
  tty to the next new tab. Counting dead tabs as existing made a launch miss its own new tab, wait out its 50
  scans and fail without typing anything; only tabs with processes count, on both sides. Each scan of about 50 tabs
  takes about 1.4 seconds, so many tabs can push a launch past the panel's 7-second cap.
- New Tab only joins the caller's tab group when that window is key in the active app; with Terminal inactive it
  opens a separate window.
- A heredoc inside `$(...)` must not contain an apostrophe, even in an AppleScript comment, or bash fails to parse
  the whole file. That goes for the generated launcher too, whose heredoc holds the prompt: bash 3.2 also let a
  stray `)` in it end the substitution and run the rest as code, so the prompt is read by a heredoc of its own
  (`tests/launcher_test.sh`).
- `bash -n a b c` checks only `a`; the rest are positional arguments.
- iTerm2 window references from a `repeat with w in windows` loop cannot be dereferenced with `contents of`;
  record `id of w` and address `window id` later.
- An AppleScript list literal built from list items (`{item 1 of out, ...} as text`) can fail to coerce; read
  values into plain variables first.
- Reading window position through System Events needs Accessibility permission for the calling terminal, and
  Ghostty's AppleScript has no `bounds`. The CoreGraphics window list gives bounds with no permission (titles need
  Screen Recording), in front-to-back order matching Ghostty's AppleScript window list (verified for Ghostty only).
- JXA cannot host C callbacks: passing a JS function as a C function pointer gets osascript killed (exit 137).
- Event taps cannot block keys here: secure input hides keystrokes from all taps.
- `NSTextAlignment` values differ between Intel and Apple Silicon, so center views by frame, not alignment.
