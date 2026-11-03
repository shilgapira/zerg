
<div align="center">
  <a href="https://github.com/shilgapira/zerg">
    <img src=".claude-plugin/icon.png" alt="Zerg Logo" width="160" height="160">
  </a>

  <h3 align="center">Zerg</h3>

  <p align="center">
    Build a project with a swarm of agent sessions
  </p>
</div>

<br />

## About

Zerg turns Claude Code into a team. A boss session plans the work and hands it out, every aspect of your project gets
a session of its own, and they all work in parallel, each in its own worktree. Finished work lands on `main`
automatically once it's reviewed and its tests pass. You step in only to give more tasks or make product decisions.

## Highlights

- **No tab juggling**: The boss opens each new session in its own tab or window, already named and briefed.
- **Simple communications**: Sessions talk through a mailbox of plain files, so a busy or compacting session misses
  nothing.
- **Picks up where it left off**: Each session keeps a state file with what it's doing and its exact next steps, so it
  carries on after a compaction, a usage-limit stop or a restart.
- **Main stays green**: Every session works on its own branch, and the boss merges an exact commit only after your
  checks pass on it. A Reviewer session looks at risky changes before they land.
- **No fighting over the machine**: Tests, builds, ports and devices that only one job should use at a time are
  taken in turns, and every job run through Zerg has a hard timeout.
- **Testing it yourself**: Tell the boss, and no new test or build starts through Zerg until you're done.
- **Stops before your plan's limit**: The team pauses before it hits the 5-hour or weekly usage limit, and picks up
  again after the reset. Just tell the boss what limit to stop at.
- **Easy to catch up**: One journal line per merge, decision and question, so you can step away and read what
  happened when you're back, or just ask the boss for a status.
- **Other computers**: Need a check on Windows, or a machine with hardware attached? Paste one prompt into an
  agent session on your network, and the boss can send it work, files and whole repos over a secure channel.
- **Other harnesses**: Is your subscription about to run out? The same secure channel works locally too, with agent
  sessions in Codex, OpenCode and others, so you can split work between subscriptions.

## Installation

Install the plugin:

```bash
claude plugin marketplace add shilgapira/zerg
claude plugin install zerg@zerg
```

To update it later:

```bash
claude plugin marketplace update zerg
claude plugin update zerg@zerg
```

Running sessions pick up the new version after `/reload-plugins`. Tell the boss you updated, so it can have the team
re-read the rules.

## Getting started

For a new project create an empty folder and start Claude Code there:

```bash
cd MyProject
claude
```

If Claude asks you whether you trust the folder, answer yes. Then start the Zerg setup by typing:

```
/zerg:setup
```

The setup then asks what you're building and which sessions you want, sets up the project and git repo for them, and
finally opens a new boss agent session. From there, you talk to the boss session.

To use Zerg with an existing project, start Claude Code in the project's directory and run `/zerg:setup` there. The
setup reads the code first, and asks you only about what it can't tell from it.

## Compatibility

- Zerg currently only supports Claude Code and Claude Desktop as the primary agent harness.
- In some running environments the boss session might need to ask you to open new sessions yourself.
- Automatic usage monitoring only works on macOS for now.
