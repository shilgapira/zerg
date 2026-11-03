# spawn in Claude Desktop

When `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop`, `launch.sh` refuses to run. Start the worker
with Desktop's own tools instead, one launch at a time, and only on a turn the user started:
Desktop refuses `start_session` on a turn another session's message started, and a relayed "the
user says" does not count. If the user did not ask for this worker, ask them in chat first and
launch on the turn where they agree; do not use `own_initiative`, whose card can start the worker
long after the auto-compact setting below has been restored.

Load the tools first: ToolSearch `select:mcp__ccd_session__start_session,mcp__ccd_session_mgmt__detach_session,mcp__ccd_session_mgmt__list_events`.

`<helper>` below is, on macOS, `<skill dir>/scripts/desktop_compact.sh`, and on
Windows (from PowerShell)
`powershell -NoProfile -ExecutionPolicy Bypass -File "<skill dir>\scripts\desktop_compact.ps1"`.
Use one `<dir>` throughout, usually your own folder: on macOS its real path (`pwd -P`), on Windows
the output of `<helper> path --dir <folder>`, since `start_session` refuses any spelling but the
exact canonical one (true case, uppercase drive letter, backslashes).

1. Check ListAgents that the worker name is not already in use (the Name convention below);
   nothing else stops a duplicate.
2. Only if the user asked for an auto-compact value, immediately before step 3:
   `<helper> set --dir <dir> --autocompact <value>`. It gives the next session started in that
   folder that window and undoes itself after 60 seconds.
3. `start_session` with: `initiation` `user_asked`; `title` = the worker name (it becomes the
   ListAgents and SendMessage name); `prompt` = the kickoff followed by the output of
   `<helper> protocol --report-to "<your name>"`; `context` fresh with a `background` of at least 80
   characters; `cwd` = `<dir>`; `use_worktree` false; `permission_mode` auto (it cannot exceed your
   own mode, so omit it if you are not in auto or bypass). Its result says to end your turn and not
   wait; do steps 4 and 5 first.
4. `detach_session` on the new session (its id is in the `start_session` result), so it is a
   sibling: without this, every worker turn notifies and may wake you. Desktop refuses to detach
   when you run in a Desktop-made worktree; the worker then stays linked and keeps notifying you.
5. If you ran step 2: `<helper> restore --dir <dir>` once the worker has started. Messages to you
   usually arrive only after your turn ends, so do not wait for the check-in within the turn:
   confirm the start with `list_events` on the worker's id, which shows that the worker has made
   its first SendMessage call (not to whom). If it still shows only the kickoff, retry after about
   10 seconds; or skip the restore and let it happen by itself 60 seconds after `set`.

## Conventions

When the calling skill gives its own rules for any of these, follow those.

1. **Name**: your call, and it must not be in use: check ListAgents first, since SendMessage
   addresses workers by exact name. Suggested: `<Area>: <Task>`, with Area one short word shared
   by related sessions (e.g. `Billing: Invoice Export`). No control characters.
2. **Prompt**: the kickoff is the whole brief (goal, context, constraints, done-criteria). The
   worker sees nothing else of your conversation, so make it self-contained and use absolute
   paths. It goes inline in `start_session`, followed by the report-back text, so a long
   compaction can lose both.
3. **Directory**: `<dir>` as above. If Desktop does not trust it yet, `start_session` waits while
   the user answers a "Trust this workspace" dialog; Cancel returns an error and starts nothing. If
   the answer takes over 60 seconds, the worker starts with the folder's normal auto-compact window.
4. **Check-in**: pass `--report-to` to `<helper> protocol` with your own name: the `<name>` in
   ListAgents' first line ("This session is <name> [ref] ..."). With its output in the prompt, the
   worker messages you when it starts, when it is done or blocked, and after each compaction; the
   kickoff need not ask for this. Without a name of your own, ask the user to name this session
   first.
5. **Permission mode**: keep `auto`, since workers run unattended; use another mode only when the
   user asks. For a planning-only task, stay in `auto` and tell the worker in the kickoff to only
   plan and change nothing.
6. **Auto-compact**: do steps 2 and 5 only when the user or the skill you follow gives a value.
7. **Verify**: `start_session` returning means only that the session was created. Wait for the
   check-in, or confirm with `list_events` (it works after detaching too). If neither shows the
   worker running, check the session before starting another; do not retry, since a retry creates
   a second session. A `start_session` error started nothing and is safe to fix and rerun.
8. **Working with it**: send follow-ups with SendMessage to the worker's title (or its `local_`
   id); its reports arrive as messages. It keeps running until the user archives it. Its reports go
   to the name you passed to `--report-to`, so if your own session is renamed later, tell the
   worker the new name.
