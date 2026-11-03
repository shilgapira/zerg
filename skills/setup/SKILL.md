---
name: setup
description: Set this git repo up for a zerg team, a boss session plus sessions that each own an area of the work in their own worktree, with a Reviewer session, coordinated through a file mailbox.
disable-model-invocation: true
---

# Setting a project up for a zerg team

One project, several Claude Code sessions at once. The **boss** hands out work, settles minor decisions and talks to the
user. **Reviewer**, which always runs, reviews risky changes. **Every other session** owns an area of the work
(examples under Product areas, below), works on its own branch in its own git worktree, and lands work through a merge
request to the boss naming an exact commit.

`task.py`, `mail.py` and `usage.py` below mean the commands `zerg task`, `zerg mail` and `zerg usage`. The rules,
scripts and templates stay in the zerg plugin; the project gets only:

| In the project | What |
|---|---|
| `etc/zerg/config.json` | Read by `task.py`: `slots`, `checks`, `tasks`, `usage_stop` (below); `version`, the plugin version that set the project up |
| `etc/zerg/project.md` | The project's setup, the user's standing preferences, product areas, the project's "ask first" list and local rules |
| `etc/notes/`, `etc/todos/`, `etc/plans/` | The team's committed knowledge (templates in `${CLAUDE_PLUGIN_ROOT}/templates/`) |
| `.claude/settings.json` | Read-only git commands and zerg's bookkeeping commands, allowed without a prompt |
| `.zerg/` (gitignored) | `team/` (`journal.md`, `runs.log`), `state/<role>.md`, `mail/<role>/`, `locks/`, `data/`, `tunnel/<role>/`, `temp/<role>/` |

Use it when the work divides into areas that can move forward at the same time. Split by what the product does, not
by files: two areas may touch some of the same files, and overlaps surface and get settled at rebase time. An area
with a steady stream of work gets a session; a bounded chunk is a task for a subagent. Too many sessions burn the
budget without visible progress.

## Steps

The bootstrap session sets the project up with the user, then hands over to a new boss session, so the boss starts
with a clean context.

### 1. Look at the repo and the machine

The stack, the build and test commands, which tools are installed, ports in use, services the project needs. The
scripts need Python 3.9 or later: if `zerg init -h` says no Python was found, on Windows offer the user to install it
for their account (`winget install Python.Python.3.12`, no admin needed); Claude Code must then be restarted to see
it. Elsewhere, ask the user to install Python 3.

### 2. Ask the user

When the repo doesn't show what the project is (an empty repo, a bare README), first ask only that, plainly: what are
we building, and for whom? Every other default depends on the answer.

Then ask everything else that isn't clear in one round, each question with a proposed default:
- the project's name, used in session titles (default: the folder's name);
- in an empty repo, what to build it with (language, framework, main tools);
- the areas of the work: the whole team the project could use, one line each with what it covers, for the user to
  cut or extend (Product areas, below);
- anything sessions should ask the user before doing, besides destructive actions, installs and writes outside the
  project (e.g. a breaking API change, a schema change, a new dependency; default: nothing else).

Ask now for everything the sessions will need from the user once: services to start (Docker, a device), browser
permissions, firewall prompts, the terminal's Automation permission (Terminal.app also Accessibility) so sessions open
in new tabs, trusting the project folder in Claude Code (a new tab stops at that prompt until then), so the checks can
be verified and nothing waits on them overnight. Questions that don't fit in the question tool go in a plain-text
list after it.

### 3. Run zerg init

In a git repository on branch `main` (`git init -b main` first if needed):

```bash
zerg init <project> --name Relay
```

It writes the files above (never overwriting one; for an existing `.claude/settings.json` it lists the allow rules to
merge in), creates the boss and Reviewer sessions (inbox, state file) and counts the `<<FILL: ...>>` markers left. The
boss creates the other sessions when it opens them.

### 4. Fill in the project files

Record the user's answers where they apply, then fill in until `grep -n '<<FILL' etc/zerg/* .zerg/state/*` finds
nothing: `project.md` (Product areas, one line per area headed by its role name; Tools and services: commands, ports,
how to start and stop each service); the focus in `.zerg/state/boss.md` (a concrete first slice with an owner per
part; an `etc/plans/` file when it needs more); `config.json` (below).

### 5. Land a skeleton, in an empty repo

A minimal skeleton for the agreed stack (build manifest, the product's folders, an empty test setup), so the checks
run and sessions start from a `main` that builds. Its checks are only what runs on that skeleton (a build, the tests,
a size limit); a check that needs real work first (a smoke run of the product, a test harness) becomes the first task
of the session that owns that area. The sessions build everything else.

### 6. Commit and verify the checks

Commit `etc/`, `.gitignore`, `.claude/settings.json` and the skeleton. Verify the checks from a fresh worktree of that
commit, `task.py --at main check --who boss --why bootstrap`, not from the checkout you built in, where installed
dependencies and generated files hide what a new worktree lacks.

### 7. Hand over to the boss

Mail the boss its first task, as boss to boss (`mail.py send --from boss --to boss ...`): "open Reviewer and the
sessions your focus needs, from Product areas in project.md". Then open the boss: `task.py open boss` prints its name,
folder, auto-compact window and kickoff file; pass them to `/zerg:spawn`, without `--report-to`. When spawn can't open
it, give the user the command and kickoff `task.py open` printed, to run and paste. The bootstrap's job ends here.

## config.json

```json
{
  "slots": {"build": 2, "db": 1},
  "checks": [
    {"name": "test", "run": ["go", "test", "./..."], "cwd": "api", "slot": "build", "timeout": 900},
    {"name": "smoke", "run": ["node", "tools/smoke.mjs"], "slot": "build", "timeout": 300,
     "env": {"SMOKE_HEADLESS": "1"}}
  ],
  "tasks": {
    "integration": {"run": ["pytest", "tests/integration"], "slot": "db", "timeout": 1800}
  },
  "usage_stop": 90
}
```

- **`slots`**: shared resources and how many jobs may use each at once: a local database, a fixed port, docker, a
  device, the running app, heavy builds.
- **`checks`**: what every merge request runs, in order, the first failure stopping it; for a product with a UI, one
  smoke run of the product itself (a headless browser loading it and failing on any error), added by the session that
  builds it (step 5). Read from the tree being checked, so a branch that changes them is checked with its own.
- **`tasks`**: recurring workflows (build, test, run, a shared stack), run as `task.py <name> [-- args]`, extra
  args appended. Each takes its slot.
- `run` is a list run without a shell, from `cwd` (relative to the tree, default its root), with `env` added. Anything
  that needs logic (a per-role database URL, a stack with up and down) is a project script named in `run`.
- **`version`**: the plugin version `zerg init` set the project up with; leave it as it is.
- No secrets in the file: a command reads them from the environment.
- Unknown keys fail loudly.

Rules for checks and tasks:
- A long job (a render, a soak test) takes its own slot, so it doesn't hold the checks' slot for half an hour.
- Checks verify, they don't fix: a check never commits or edits source files. When a generator can only write in
  place, the check runs it and fails if the generated folders changed, telling the session to review and commit.
- A check fails, never skips, when something it needs is down: a skipped test looks exactly like a passing one.
- Every long-running task (a server, a stack) says how to stop it, in `project.md`.

## Product areas

Propose the whole team the project could use. Each area becomes a Product areas line, and the boss opens a session for
it only when the work in hand needs it, so a long list costs nothing until then. An area is work that needs a long
memory of its own: its code or material, its tools, its decisions so far. Some teams, besides the boss and Reviewer:

- **A web product with a mobile app**: Server builds the API, storage and auth; Web and Mobile build the two clients
  against it; E2E writes tests that drive both clients against a running server; Docs keeps the user guide and the
  API reference in step with what lands.
- **A mobile fighting game**: Combat works on the moves, weapons and interactions between characters; AI improves
  how computer-controlled characters fight; Netplay builds multiplayer over LAN; Art draws the sprites, animations and
  menus; Audio makes the sound effects and music; Performance measures load time, frame rate and battery use on a
  low-end device against a baseline, and hands each regression to its owner.
- **A graphics editor**: Interface builds the panels, toolbars, menus and shortcuts; Canvas owns the document model
  (layers, masks, blend modes) and compositing; Tools makes the brushes, selections and transforms; Filters writes
  the filters and adjustment layers; Formats opens and saves PNG, JPEG, TIFF and PSD, tested against a collection of
  real files; Plugins designs the plugin API and a sample plugin; AI adds generative fill and background removal,
  with evals of their output; Performance measures brush latency and filter time on large images against a baseline;
  Testing compares rendered images with approved ones, pixel by pixel.
- **A product built on a language model**: Backend serves the feature and calls the model; Prompts designs the
  prompts and tools; Data collects and cleans real examples; Evals keeps scored test sets and reports, for every
  prompt or model change, what got better and what got worse; Research reads up on techniques before a design.
- **A library with bindings**: Core writes the library; Python and Node wrap it; Compat runs the test suite on other
  operating systems and versions, on another computer through `/zerg:tunnel` when needed; Docs writes the guides and
  examples.

A small tool may need two areas; a product with several clients, or a game, often has six to ten. An area's line in
Product areas carries its own working rules too, such as a Performance area measuring in a quiet window
(`task.py usertest --for performance`), old and new back to back.

- Split by what a session needs to know, not by folder: two areas whose tasks change the same code most of the time
  are one area.
- A common library used by several areas belongs to one of them, or becomes an area of its own.
- Research-only sessions are fine: a session can own only notes and plans until its area's work starts.

## Shared services, data and caches

- **One instance of a heavy service** (a database server, a compose stack) for every worktree, started from the main
  checkout with a fixed name by a project script named in a task; its port in `project.md`. Isolation inside it per
  role (a database or schema per role), so tests don't reset each other's data; only what can't be split takes a
  slot. A server per worktree gets its own port and a `port-<role>` slot each.
- **A resource driven through a tool, not a command** (the user's browser through an extension) can't take a slot:
  one session owns it, the others ask that session; say so in `project.md`.
- **Shared data** lives in `.zerg/data/<role>/` of the role that fetches it, passed to tasks as an absolute path,
  never copied into worktrees.
- **Build output** stays in each worktree, where the tool puts it; **download caches** are shared through each tool's
  own global cache; **scratch output** the tool lets you place goes in `.zerg/temp/<role>/`.
