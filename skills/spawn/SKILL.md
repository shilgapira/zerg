---
name: spawn
description: Start a new named Claude Code session in a new tab or window with a kickoff prompt, so an orchestrating session can spin up other sessions in the same application running it without the user opening, naming and briefing sessions by hand. Use when the user says /zerg:spawn, "spin up a session", "start a worker session", "open a new session for X", or when a plan calls for handing a task to a separate named session.
---

# /zerg:spawn - launch a new named session

If you are running in Claude Desktop (`CLAUDE_CODE_ENTRYPOINT` is `claude-desktop`, or `mcp__ccd_session__start_session`
is among your tools, possibly deferred), read and follow `${CLAUDE_SKILL_DIR}/references/claude-desktop.md`. Otherwise
read and follow `${CLAUDE_SKILL_DIR}/references/terminal.md`. `<skill dir>` in those files means `${CLAUDE_SKILL_DIR}`.
