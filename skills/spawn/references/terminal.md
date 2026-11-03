# spawn in a terminal

`launch.sh` opens a new tab or window and starts a named `claude` session there with your
kickoff prompt.

```bash
<skill dir>/scripts/launch.sh \
  --name "<session name>" \
  --prompt-file <scratchpad>/<slug>-kickoff.md \
  --dir <trusted project folder> \
  [--report-to "<your own session name>"] \
  [--permission-mode <auto|plan|acceptEdits|...>, default auto] \
  [--autocompact <auto|100k-1M, default auto; 200 means 200k>] \
  [--dry-run]
```

Run it in the foreground, one launch at a time (concurrent launches race for the terminal). It
prints `launched: <name>` on success; on failure it exits non-zero with `spawn: <reason>`.
`--dry-run` checks the arguments and terminal and prints the launcher without opening a tab.

**What to expect:**

- Supported: Terminal.app, iTerm2 and Ghostty 1.3+ on macOS; tmux when the caller is already in
  tmux; Windows Terminal on Windows. Other terminals fail with an error.
- Terminal.app and Ghostty take about 6 seconds and briefly come to the front, then the user's
  focus is restored; iTerm2 returns at once and stays in the background.
- Windows Terminal opens the tab in its most recently focused window and switches to it.
- First use may show macOS Automation or Accessibility prompts for the user to approve.
  Terminal.app requires Accessibility and an English menu bar; without them the launch fails.

## Conventions

When the calling skill gives its own rules for any of these, follow those.

1. **Name**: your call, and it must not be in use: check ListAgents first, since SendMessage
   addresses workers by exact name. Suggested: `<Area>: <Task>`, with Area one short word shared
   by related sessions (e.g. `Billing: Invoice Export`). No control characters.
2. **Prompt**: the prompt file is the whole brief (goal, context, constraints, done-criteria). The
   worker sees nothing else of your conversation, so make it self-contained and use absolute
   paths. Write it to your scratchpad, and delete it once `launch.sh` prints `launched:`, since the
   launch keeps its own copy; a prompt file another tool wrote stays where it is.
3. **Directory**: always pass `--dir`. The default is the shell's current directory at call time,
   which drifts. The folder must be one Claude Code already trusts (a project, not `~`), or the
   worker stops at the trust prompt and never starts.
4. **Check-in**: pass `--report-to` with your own name: the `<name>` in ListAgents' first line
   ("This session is <name> [ref] ..."). The worker then messages you when it starts, when it is
   done or blocked, and after each compaction; the kickoff need not ask for this. Without a name of
   your own, ask the user to name this session first.
5. **Permission mode**: keep `auto`, since workers run unattended; use another mode only when the
   user asks. For a planning-only task, stay in `auto` and tell the worker in the kickoff to only
   plan and change nothing.
6. **Auto-compact**: pass `--autocompact` only when the user or the skill you follow gives a value.
7. **Verify**: neither `launched:` nor the panel means the worker is up. Wait for the check-in, or
   (without `--report-to`) call ListAgents after a few seconds and look for the exact name. If it
   is missing, tell the user which tab to look at; do not retry, since a retry opens a second tab.
   A `spawn:` error before any tab opened is safe to fix and rerun.
8. **Working with it**: send follow-ups with SendMessage to the worker's name; its reports arrive
   as messages. It keeps running until someone exits it.
