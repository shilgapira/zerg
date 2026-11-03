"""The team's task runner: locks, checks, squash, merge, bookkeeping. Run with no arguments for the list. Run it
from your worktree (or the main checkout): it acts on the git tree of the current directory.

    task.py run --slot NAME [--timeout S] -- COMMAND...
                                     run COMMAND holding one of NAME's slots, with a hard timeout, output to
                                     .zerg/temp/<who>/, two lines per task in .zerg/team/runs.log (needs --who, --why)
    task.py NAME [--timeout S] [-- ARGS...]
                                     a task from etc/zerg/config.json "tasks", ARGS appended to its command
    task.py slots                    who holds which slot, and whether the user is testing
    task.py usertest [MINUTES] [--for ROLE] [--slots A,B] [--no-wait] | usertest --end
                                     keep automated runs off the machine while the user tests (default 120), or all
                                     but ROLE's (a quiet window for a benchmark); only the named slots with --slots;
                                     waits for running jobs to finish unless --no-wait; --end lifts it
    task.py todos                    open items in etc/todos by priority, fails on a malformed one
    task.py todos next --who ROLE    take the next todo number from a counter shared by every worktree
    task.py squash -m MSGFILE --who ROLE --why TEXT [--deletes F] [--restores F]
                                     rebase on main and squash the branch to one commit with MSGFILE's message, in one
                                     step; refuses a commit that changes files the branch's own commits never touched,
                                     and squashing while your branch holds a pending merge request
    task.py check --who ROLE --why TEXT [--deletes F] [--restores F]
                                     the stale-base guard, then the checks of this tree's etc/zerg/config.json
    task.py prepare HASH --from ROLE boss, before a merge: pass HASH through when it is one commit on top of main
                                     whose checks passed clean, else rebase and check it in a throwaway tree; prints
                                     the merge command, or the "returned" mail on a conflict
    task.py merge HASH --from ROLE:SENT-HASH
                                     boss only: fast-forward main to HASH from a clean main checkout, journal it, and
                                     mail "merged" to the sender
    task.py journal "LINE"           one time-stamped line in .zerg/team/journal.md (needs --who)
    task.py audit [BASE]             unmerged work per branch and worktree, marking commits that already landed (same
                                     patch)
    task.py open ROLE [--title T] [--autocompact 500k]
                                     what /zerg:spawn needs to open a session (refused while it is listening), and the
                                     command and kickoff the user can run and paste instead; the first time, creates
                                     the session (inbox, state file) and needs --title
    task.py --at HASH TASK ...       run TASK in a throwaway worktree at HASH, so the exact bytes are checked (with
                                     that commit's checks) and your own worktree stays free

`task.py` is this file, run as `zerg task`. Slots, tasks and the usage stop come from the main
checkout's etc/zerg/config.json; checks from the config of the tree being checked. Locks live in the main checkout's
.zerg/locks/, so every worktree sees them. A user test blocks every slot unless it names some. Stopping a job by
killing task.py's PID works on macOS and Linux; on Windows, `taskkill /T` the job's own PID.
"""

from __future__ import annotations

import argparse
import contextlib
import functools
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

SKILL = Path(os.path.abspath(__file__)).parents[1]
LOCK_POLL_S = 2.0
TODO_FIELDS = ("Priority", "Status", "Risk")
PRIORITIES = {"High": 0, "Medium": 1, "Low": 2}
STATUSES = ("Ready", "Needs decision", "Needs evidence", "Needs direction", "Watching", "Parked")

RUN_INFO: dict[str, str] = {}
ROLE_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
CONFIG = Path("etc") / "zerg" / "config.json"
CONFIG_KEYS = {"slots", "checks", "tasks", "usage_stop", "version"}
COMMAND_KEYS = {"run", "slot", "timeout", "cwd", "env"}
BUILTINS = ("run", "slots", "usertest", "todos", "squash", "check", "prepare", "merge", "journal", "audit", "open")
# Reviewer does short tasks, so a smaller auto-compact window.
DEFAULT_AUTOCOMPACT = {"reviewer": "300k"}
AUTOCOMPACT_RE = re.compile(r"^(auto|[0-9]{1,7}[km]?)$")

JOBS = {"boss": "hands out work, settles minor decisions, writes main, reports to the user (references/boss.md)",
        "reviewer": "reviews changes their owners judge risky, and what the boss asks it to review; never commits "
                    "(references/reviewer.md)"}


def autocompact_ok(value: str) -> bool:
    """The CLI's rule, as spawn checks it: auto, or 100k to 1M tokens; a bare number under 10000 counts in thousands."""
    if value == "auto":
        return True
    m = AUTOCOMPACT_RE.match(value)
    if not m:
        return False
    n = int(value.rstrip("km"))
    n *= 1000 if value.endswith("k") or (value.isdigit() and n < 10000) else 1_000_000 if value.endswith("m") else 1
    return 100_000 <= n <= 1_000_000


def toplevel() -> Path:
    proc = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode:
        sys.exit(f"task: {Path.cwd()} is not in a git repository: run task.py from your worktree")
    return Path(proc.stdout.strip()).resolve()


ROOT = toplevel()


def git(*args: str, cwd: Path = ROOT, check: bool = True) -> str:
    # quotePath off: file names come back as they are, not as "\303\251"-style escapes
    proc = subprocess.run(["git", "-c", "core.quotePath=false", *args], cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if check and proc.returncode:
        sys.exit(f"task: git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


@functools.cache
def main_checkout() -> Path:
    return (ROOT / git("rev-parse", "--git-common-dir").strip()).resolve().parent


@functools.cache
def lock_dir() -> Path:
    path = mailbox().parent / "locks"
    path.mkdir(exist_ok=True)
    return path


def mailbox() -> Path:
    box = main_checkout() / ".zerg" / "mail"
    if not box.is_dir():
        sys.exit(f"task: no mailbox at {box}: is this a zerg project?")
    return box


@functools.cache
def known_roles() -> list[str]:
    return sorted(p.name for p in mailbox().iterdir() if p.is_dir())


def load_config(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        tree = path.parents[len(CONFIG.parts) - 1]
        sys.exit(f"task: no {CONFIG.as_posix()} in {tree}: not a zerg project, or a commit from before it")
    except ValueError as e:
        sys.exit(f"task: {path} is not valid JSON: {e}")
    def fail(why: str):
        sys.exit(f"task: {path}: {why}")
    if not isinstance(data, dict):
        fail("expected an object")
    if extra := set(data) - CONFIG_KEYS:
        fail(f"unknown keys {', '.join(sorted(extra))} (known: {', '.join(sorted(CONFIG_KEYS))})")
    slots = data.setdefault("slots", {})
    if not isinstance(slots, dict) or not all(isinstance(v, int) and v > 0 for v in slots.values()):
        fail('"slots" is {"name": capacity, ...} with whole numbers above 0')
    commands = [(f"checks[{i}]", c) for i, c in enumerate(data.setdefault("checks", []))]
    commands += [(f"tasks.{n}", c) for n, c in data.setdefault("tasks", {}).items()]
    for where, c in commands:
        if not isinstance(c, dict):
            fail(f"{where} is not an object")
        if extra := set(c) - COMMAND_KEYS - ({"name"} if where.startswith("checks") else set()):
            fail(f"{where} has unknown keys {', '.join(sorted(extra))}")
        if not (isinstance(c.get("run"), list) and c["run"] and all(isinstance(a, str) for a in c["run"])):
            fail(f'{where}.run is a list of strings, e.g. ["go", "test", "./..."] (run without a shell)')
        if not isinstance(c.get("slot"), str) or not isinstance(c.get("timeout"), (int, float)):
            fail(f"{where} needs a slot name and a timeout in seconds")
        if not isinstance(c.get("env", {}), dict):
            fail(f"{where}.env is an object of strings")
    for name in data["tasks"]:
        if name in BUILTINS or not ROLE_RE.match(name):
            fail(f"tasks.{name}: a task name is lower case, not one of task.py's own ({', '.join(BUILTINS)})")
    usage_stop = data.get("usage_stop", 90)
    if not isinstance(usage_stop, (int, float)):
        fail('"usage_stop" is a percentage')
    return data


@functools.cache
def team_config() -> dict:
    return load_config(main_checkout() / CONFIG)


def slots() -> dict[str, int]:
    return team_config()["slots"]


def has_commits() -> bool:
    return not subprocess.run(["git", "rev-parse", "--verify", "-q", "HEAD"], cwd=ROOT, capture_output=True).returncode


def scratch() -> Path:
    path = main_checkout() / ".zerg" / "temp" / (RUN_INFO.get("who") or "unknown")
    path.mkdir(parents=True, exist_ok=True)
    return path


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        # os.kill(pid, 0) terminates the process on Windows, so ask the kernel instead
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel32.CloseHandle(handle)
        return code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def hold_lock() -> Path:
    return lock_dir() / "hold.lock"


def slot_locks(name: str) -> list[Path]:
    if name not in slots():
        sys.exit(f"task: unknown slot {name!r}, known: {', '.join(slots()) or 'none'} "
                 "(\"slots\" in etc/zerg/config.json)")
    return [lock_dir() / f"{name}-{i}.lock" for i in range(slots()[name])]


def lock_entry(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        # its holder may be rewriting it: held briefly from its mtime, so a holder that died mid-write can't block it
        try:
            created = path.stat().st_mtime
        except OSError:
            return None
        return {"pid": 0, "who": "?", "command": "?", "since": created, "lease": 10, "token": "?"}


def is_live(held: dict) -> bool:
    """The holder's job counts too: a task killed with -9 can't clean up, and its job runs on in its own group."""
    alive = not held["pid"] or pid_alive(held["pid"]) or (held.get("job") and pid_alive(held["job"]))
    return bool(alive) and time.time() <= held["since"] + held["lease"]


def write_new(path: Path, entry: dict) -> bool:
    """Creates `path` only if absent, never empty: written aside, then hard-linked."""
    tmp = path.with_name(f".{path.name}.{os.getpid()}-{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(entry), encoding="utf-8")
    try:
        os.link(tmp, path)
        return True
    except OSError:
        # FileExistsError, or PermissionError while Windows still deletes the previous holder's file
        return False
    finally:
        tmp.unlink(missing_ok=True)


def break_stale(path: Path) -> None:
    """Renamed aside, and put back if live: of two waiters breaking the same stale lock, the second may grab the fresh
    lock the first just took."""
    aside = path.with_name(f"{path.name}.stale-{os.getpid()}-{time.time_ns()}")
    try:
        os.replace(path, aside)
    except OSError:
        # gone already, or Windows still has it open: the next poll tries again
        return
    held = lock_entry(aside)
    if held is not None and is_live(held):
        with contextlib.suppress(OSError):
            write_new(path, held)
    with contextlib.suppress(OSError):
        aside.unlink(missing_ok=True)


def read_lock(path: Path) -> dict | None:
    held = lock_entry(path)
    if held is None or is_live(held):
        return held
    break_stale(path)
    return None


def try_lock(path: Path, entry: dict) -> bool:
    if read_lock(path) is not None:
        return False
    entry["since"] = time.time()
    if not write_new(path, entry):
        return False
    entry["path"] = str(path)
    return True


def unlock(path: Path, entry: dict) -> None:
    for _ in range(100):
        try:
            if json.loads(path.read_text(encoding="utf-8")).get("token") == entry["token"]:
                path.unlink(missing_ok=True)
            return
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            # Windows refuses to delete a file another process is reading at that moment
            time.sleep(0.05)
    print(f"task: WARNING could not release {path}, it expires after its lease", flush=True)


def new_entry(lease: float, kind: str, pid: int | None = None) -> dict:
    now = time.time()
    return {"pid": os.getpid() if pid is None else pid, "who": RUN_INFO.get("who", ""),
            "command": RUN_INFO.get("command", ""), "since": now, "lease": lease, "kind": kind,
            "token": f"{os.getpid()}-{now}"}


def wait_note(what: str, held: dict | None, waited: float) -> float:
    if waited % 30 < LOCK_POLL_S:
        by = f" held by {held['who'] or '?'} ({held['command']}) for {time.time() - held['since']:.0f}s" if held else ""
        print(f"task: waiting for {what}{by}", flush=True)
    time.sleep(LOCK_POLL_S)
    return waited + LOCK_POLL_S


@contextlib.contextmanager
def slot(name: str, lease: float):
    entry = new_entry(lease, name)
    waited = 0.0
    taken = None
    try:
        while True:
            hold = read_lock(hold_lock())
            if hold and hold.get("for") != RUN_INFO.get("who") and name in hold.get("slots", slots()):
                waited = wait_note("the user test to end,", hold, waited)
                continue
            taken = next((p for p in slot_locks(name) if try_lock(p, entry)), None)
            if taken is not None:
                break
            waited = wait_note(f"a {name} slot,", next(filter(None, map(read_lock, slot_locks(name))), None), waited)
        yield entry
    finally:
        if taken is not None:
            unlock(taken, entry)


def all_slot_locks() -> list[Path]:
    return [p for name in slots() for p in slot_locks(name)]


def log_start() -> None:
    """Once, at the task's first job; main() logs the end."""
    if "began" not in RUN_INFO:
        RUN_INFO["began"] = str(time.time())
        log_run("start", why=repr(RUN_INFO["why"]))


def log_end(error: str = "") -> None:
    if "began" in RUN_INFO and "ended" not in RUN_INFO:
        RUN_INFO["ended"] = "1"
        seconds = f"{time.time() - float(RUN_INFO['began']):.1f}"
        log_run("failed" if error else "done", seconds=seconds, **({"error": error} if error else {}))


def log_run(event: str, **fields: str) -> None:
    """CHECK_DONE parses these fields in this order: change both together."""
    status = git("status", "--porcelain=v2", "--branch", "--untracked-files=no", check=False).splitlines()
    head = next((line.split()[2][:9] for line in status if line.startswith("# branch.oid")), "none")
    dirty = "yes" if any(not line.startswith("#") for line in status) else "no"
    parts = [time.strftime("%Y-%m-%d %H:%M:%S"), f"{event:<6}", f"who={RUN_INFO['who']}", f"worktree={ROOT.name}",
             f"head={head}", f"dirty={dirty}", f"task={RUN_INFO['command']!r}",
             *(f"{k}={v}" for k, v in fields.items())]
    path = main_checkout() / ".zerg" / "team" / "runs.log"
    path.parent.mkdir(exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write("  ".join(parts) + "\n")


def check_role(role: str) -> str:
    role = role.strip().lower()
    if not ROLE_RE.match(role):
        sys.exit(f"task: {role!r} is not a role name (lower case letters, digits, - and _)")
    if role not in known_roles():
        sys.exit(f"task: unknown role {role!r}, known: {', '.join(known_roles())} "
                 "(task.py open ROLE --title ... creates one)")
    return role


def need_who_why() -> None:
    if not (RUN_INFO["who"] and RUN_INFO["why"]):
        sys.exit("task: this task needs --who ROLE --why \"what it checks\"")


def kill_tree(proc: subprocess.Popen) -> None:
    """By PID, never by image name: other sessions run the same programs."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
    else:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)


def run_job(slot_name: str, command: list[str], timeout: float, cwd: Path | None = None,
            env: dict[str, str] | None = None, name: str = "") -> None:
    """Exits the process when the command fails or times out."""
    need_who_why()
    if not command:
        sys.exit("task: run needs a command after --")
    name = name or re.sub(r"[^\w.]+", "-", " ".join(Path(a).name for a in command[:3]))[:40].strip("-")
    with slot(slot_name, timeout + 60) as entry:
        log_start()
        group = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
                 else {"start_new_session": True})
        try:
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    encoding="utf-8", errors="replace", cwd=cwd,
                                    env={**os.environ, **env} if env else None, **group)
        except OSError as e:
            log_end(repr(f"{name}: {e}"))
            sys.exit(f"task: could not start {command[0]!r}: {e}")
        entry["job"] = proc.pid
        with contextlib.suppress(OSError):
            Path(entry["path"]).write_text(json.dumps(entry), encoding="utf-8")
        log_path = scratch() / f"{name}-{time.strftime('%Y%m%d-%H%M%S')}-{proc.pid}.log"
        print(f"task: {' '.join(command)[:100]} (slot {slot_name}, timeout {timeout:.0f}s, log {log_path})",
              flush=True)
        timed_out = threading.Event()
        timer = threading.Timer(timeout, lambda: (timed_out.set(), kill_tree(proc)))
        timer.start()
        # the job has its own process group, so stopping this task (kill <pid from `task.py slots`>) must stop it too
        for stop in (signal.SIGTERM, signal.SIGINT):
            signal.signal(stop, lambda *_: (kill_tree(proc), sys.exit("task: stopped")))
        try:
            with open(log_path, "w", encoding="utf-8") as log:
                for line in proc.stdout:
                    log.write(line)
                    log.flush()
                    print("  " + line.rstrip(), flush=True)
        finally:
            proc.wait()
            timer.cancel()
    failed = proc.returncode != 0
    error = "timeout" if timed_out.is_set() else f"exit {proc.returncode}"
    if failed:
        log_end(f"{name}: {error}")
        sys.exit(f"task: failed ({error}), see {log_path}")
    # on stderr, so a run piped through grep still says where its full output is
    print(f"task: full output in {log_path}", file=sys.stderr, flush=True)


def run_command(c: dict, name: str = "", extra: list[str] = (), timeout: float | None = None) -> None:
    run_job(c["slot"], [*c["run"], *extra], timeout or c["timeout"], cwd=ROOT / c.get("cwd", "."),
            env={k: str(v) for k, v in c.get("env", {}).items()}, name=name)


def cmd_run(ns: argparse.Namespace) -> None:
    run_job(ns.slot, ns.args, ns.timeout)


def cmd_task(ns: argparse.Namespace) -> None:
    run_command(team_config()["tasks"][ns.task], name=ns.task, extra=ns.args, timeout=ns.timeout)


def cmd_open(ns: argparse.Namespace) -> None:
    role = ns.role.strip().lower()
    if not ROLE_RE.match(role):
        sys.exit(f"task: {role!r} is not a role name (lower case letters, digits, - and _)")
    if role == "all":
        sys.exit("task: 'all' is taken: mail to all goes to every session")
    main = main_checkout()
    state = main / ".zerg" / "state" / f"{role}.md"
    if (main / ".zerg" / "tunnel" / role).is_dir():
        sys.exit(f"task: {role} is a session on another computer, reached through `zerg tunnel`: a session here "
                 f"would take its mail. `zerg tunnel status {role}`; `zerg tunnel open {role}` reprints its prompt")
    if not state.exists():
        create_session(role, main, state, ns.title, ns.autocompact)
    elif ns.title or ns.autocompact:
        sys.exit(f"task: {role} exists already: edit the first line or the Autocompact line of {state}")
    (mailbox() / role / "read").mkdir(parents=True, exist_ok=True)
    text = state.read_text(encoding="utf-8-sig")  # -sig: a Windows editor may have added a BOM
    if not (m := re.match(r"# Session: (.+?) \(mail role ", text)):
        sys.exit(f"task: {state} doesn't start with '# Session: <title> (mail role {role})'")
    title = m[1]
    found = m[1] if (m := re.search(r"Autocompact: ([0-9a-zA-Z]+)", text)) else ""
    autocompact = (found or DEFAULT_AUTOCOMPACT.get(role, "500k")).lower()
    if not autocompact_ok(autocompact):
        sys.exit(f"task: the Autocompact line of {state} is auto or 100k to 1m, such as 300k, not {autocompact!r}")
    if waiter_live(role):
        sys.exit(f"task: {role} is listening (its mail waiter runs), so it is open already; exit that session first "
                 "if you mean to restart it")
    prompt = main / ".zerg" / "temp" / role / "kickoff.md"
    prompt.parent.mkdir(parents=True, exist_ok=True)
    prompt.write_text(kickoff(role, title, main) + "\n", encoding="utf-8")
    print(f"Open {title} with /zerg:spawn, with no --report-to (it counts as open once `zerg mail status` shows it\n"
          f"listening):\n  name: {title}\n  folder: {main.as_posix()}\n  autocompact: {autocompact}\n"
          f"  prompt file: {prompt.as_posix()}\n\n"
          f"If spawn can't open it, ask the user to open a new Claude Code session in {main.as_posix()}, started as\n"
          f"  claude -n {quote_title(title)} --permission-mode auto --autocompact {autocompact}\n"
          f"and to paste this as its first prompt:\n\n{kickoff(role, title, main)}")


def create_session(role: str, main: Path, state: Path, title: str | None, autocompact: str | None) -> None:
    title = (title or "").strip()
    if not title:
        sys.exit(f'task: {role} has no session yet: give its name, task.py open {role} --title "<Project> <Area>"')
    # the title is the state file's first line, "# Session: <title> (mail role <role>)", read back by open and status
    if any(ord(c) < 32 for c in title) or "(mail role" in title:
        sys.exit(f"task: --title is one line of plain text, without '(mail role': {title!r}")
    autocompact = (autocompact or DEFAULT_AUTOCOMPACT.get(role, "500k")).lower()
    if not autocompact_ok(autocompact):
        sys.exit(f"task: --autocompact is auto or 100k to 1m, such as 300k, not {autocompact!r}")
    (mailbox() / role / "read").mkdir(parents=True, exist_ok=True)
    (main / ".zerg" / "temp" / role).mkdir(parents=True, exist_ok=True)
    worktree = {"boss": "the main checkout, on main",
                "reviewer": f"none: a throwaway tree per review in {main.as_posix()}/.zerg/temp/reviewer/<hash>"}.get(
        role, f"{main.as_posix()}/.claude/worktrees/{role}, on branch {role}")
    job = JOBS.get(role, f"its area and standing orders: **{role}** under Product areas in "
                         f"{main.as_posix()}/etc/zerg/project.md")
    values = {"TITLE": title, "ROLE": role, "MAIN": main.as_posix(), "WORKTREE": worktree, "JOB": job,
              "AUTOCOMPACT": autocompact,
              "FOCUS": "## Focus (replace when the user sets a new goal)\n- <<FILL: the user's goal now, a first slice "
                       "with an owner per part>>\n\n" if role == "boss" else ""}
    text = (SKILL / "templates" / "session.md").read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    state.parent.mkdir(parents=True, exist_ok=True)
    with open(state, "w", encoding="utf-8", newline="\n") as f:  # write_text has no newline= before 3.10
        f.write(text)
    print(f"task: created {role} ({state})")


def waiter_live(role: str) -> bool:
    """Mirrors mail.py's rule for a live waiter."""
    try:
        beat = json.loads((mailbox() / role / ".waiting").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    pid = beat.get("pid")
    return (not beat.get("ended") and time.time() - beat.get("time", 0) < 30 and isinstance(pid, int)
            and pid_alive(pid))


def quote_title(title: str) -> str:
    """Double quotes for a plain title, which every shell reads alike (cmd.exe has no single quotes)."""
    return f'"{title}"' if re.fullmatch(r"[\w .-]+", title) else shlex.quote(title)


def kickoff(role: str, title: str, main: Path) -> str:
    return (f"/zerg:join {role}\n\nYou are {title}, mail role {role}. The main checkout is {main.as_posix()}: the "
            ".zerg/ folder lives only there and is shared by all sessions. Your state file is "
            f"{main.as_posix()}/.zerg/state/{role}.md; your first task is in your mail.")


def cmd_slots(_: argparse.Namespace) -> None:
    for path in [hold_lock(), *all_slot_locks()]:
        held = read_lock(path)
        state = (f"{held['who'] or '?'}: {held['command']} for {time.time() - held['since']:.0f}s"
                 + (f" (pid {held['pid']})" if held.get("pid") else "")
                 + (f" (only {', '.join(held['slots'])})" if held.get("slots") else "")
                 + (f" (lets {held['for']} through)" if held.get("for") else "")) if held else "free"
        print(f"{path.stem:<12} {state}")


def cmd_usertest(ns: argparse.Namespace) -> None:
    if ns.end:
        held = read_lock(hold_lock())
        if held is None:
            print("task: no user test set")
            return
        unlock(hold_lock(), held)
        print("task: user test over, automated runs start again", flush=True)
        return
    entry = new_entry(ns.minutes * 60, "usertest", pid=0)
    entry["who"], entry["command"] = "USER TEST (task.py usertest)", "the user is testing, ask the boss"
    if ns.for_role:
        entry["who"], entry["for"] = f"QUIET WINDOW for {ns.for_role}", check_role(ns.for_role)
    names = [n.strip() for n in ns.slots.split(",") if n.strip()] if ns.slots else list(slots())
    for name in names:
        slot_locks(name)  # fails loudly on an unknown slot
    if ns.slots:
        entry["slots"] = names
    waited = 0.0
    while not try_lock(hold_lock(), entry):
        waited = wait_note("the previous user test to end,", read_lock(hold_lock()), waited)
    waited = 0.0
    locks = [p for name in names for p in slot_locks(name)]
    while not ns.no_wait and (held := next((h for h in map(read_lock, locks) if h and h["who"] != entry.get("for")),
                                           None)):
        waited = wait_note("running jobs,", held, waited)
    but = f" but {entry['for']}'s" if entry.get("for") else ""
    on = f" on {', '.join(names)}" if ns.slots else ""
    running = " (running jobs may still finish)" if ns.no_wait else ""
    print(f"task: set for {ns.minutes:g} minutes: nothing automated{but} starts{on} until `task.py usertest --end`"
          + running, flush=True)


def todo_fields(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    fields = {}
    for name in TODO_FIELDS:
        m = re.search(rf"^- \*\*{name}\*\*: (.+)$", text, re.M)
        if not m:
            sys.exit(f"task: {path.name} has no {name} field")
        fields[name] = m.group(1).strip()
    if fields["Priority"] not in PRIORITIES:
        sys.exit(f"task: {path.name} has an unknown priority {fields['Priority']!r}")
    if not fields["Status"].startswith(STATUSES):
        sys.exit(f"task: {path.name} has an unknown status {fields['Status']!r}, one of: {', '.join(STATUSES)}")
    if fields["Status"].startswith("Watching") and not re.search(r"^- \*\*Trigger\*\*: ", text, re.M):
        sys.exit(f"task: {path.name} is Watching without a Trigger field")
    fields["title"] = text.splitlines()[0].lstrip("# ").strip()
    return fields


def worktree_paths() -> list[Path]:
    return [Path(line[9:]) for line in git("worktree", "list", "--porcelain").splitlines()
            if line.startswith("worktree ")]


def next_todo_number() -> int:
    counter = lock_dir() / "todo-counter"
    if counter.exists():
        last = int(counter.read_text(encoding="utf-8").strip() or 0)
    else:
        names = [p.name for tree in worktree_paths() for p in (tree / "etc" / "todos").glob("*.md")]
        last = max((int(m[1]) for name in names if (m := re.match(r"(\d+)-", name))), default=0)
    counter.write_text(f"{last + 1}\n", encoding="utf-8")
    return last + 1


def cmd_todos(ns: argparse.Namespace) -> None:
    folder = ROOT / "etc" / "todos"
    if ns.action == "next":
        if not RUN_INFO["who"]:
            sys.exit("task: todos next needs --who ROLE (recorded with the number)")
        entry = new_entry(30, "todo-number")
        waited = 0.0
        while not try_lock(lock_dir() / "todo-number.lock", entry):
            waited = wait_note("the todo counter,", read_lock(lock_dir() / "todo-number.lock"), waited)
        try:
            print(f"{next_todo_number():03d}")
        finally:
            unlock(lock_dir() / "todo-number.lock", entry)
        return
    rows = []
    for path in sorted(folder.glob("*.md")):
        f = todo_fields(path)
        rows.append((PRIORITIES[f["Priority"]], f["Priority"], f["Status"], f["title"]))
    for _, prio, status, title in sorted(rows):
        print(f"{prio:<8} {status[:22]:<22} {title}")


def main_hash() -> str:
    """Callers pass the hash, not `main`, so a file or folder named `main` can't make git read it as a path."""
    return git("rev-parse", "--verify", "refs/heads/main^{commit}").strip()


def branch_files(onto: str) -> set[str]:
    base = git("merge-base", onto, "HEAD").strip()
    return set(git("diff", "--name-only", "--no-renames", base, "HEAD").splitlines())


def base_problems(deletes: list[str], restores: list[str], allowed: set[str] | None = None,
                  onto: str = "") -> list[str]:
    """Signs of a commit squashed on a stale base, which silently reverts what landed on main since."""
    main = main_hash()
    if onto and onto != main:
        return [f"main moved during the squash ({onto[:7]} -> {main[:7]}): run squash again"]
    if git("rev-parse", "HEAD").strip() == main:
        return []
    if subprocess.run(["git", "merge-base", "--is-ancestor", main, "HEAD"], cwd=ROOT).returncode:
        return ["HEAD is not on top of main: `task.py squash` rebases first"]
    deletes, restores = [Path(f).as_posix() for f in deletes], [Path(f).as_posix() for f in restores]
    problems = []
    for line in git("diff", "--name-status", "--no-renames", main, "HEAD").splitlines():
        status, path = line.split("\t", 1)
        if allowed is not None and path not in allowed and path not in deletes + restores:
            problems.append(f"changes {path}, which the branch's own commits never touched")
        elif status == "D" and path not in deletes:
            problems.append(f"deletes {path} (name it with --deletes if meant)")
        elif status == "M" and path not in restores:
            blob = git("rev-parse", f"HEAD:{path}").strip()
            # each of main's recent commits to the file, with the blob it replaced
            raw = git("log", "-n", "30", "--format=commit %H", "--raw", "--no-abbrev", main, "--", path)
            commit = ""
            for row in raw.splitlines():
                if row.startswith("commit "):
                    commit = row[7:]
                elif row.startswith(":") and row.split()[2] == blob:
                    problems.append(f"sets {path} back to its version before main's {commit[:7]} (--restores if meant)")
                    break
    return problems


def pending_requests(role: str) -> list[tuple[str, str]]:
    """(hash, subject) of this role's merge requests that no "merged", "returned" or "withdraw" mail answered."""
    box = mailbox()
    def subjects(paths):
        for path in paths:
            try:
                head = path.read_text(encoding="utf-8", errors="replace").splitlines()[:5]
            except FileNotFoundError:
                continue  # a reader moved it to read/ after the glob
            for line in head:
                if line.startswith("Subject: "):
                    yield line[9:].strip()
    sent = {m[1]: subject for subject in subjects(p for p in box.glob("*/**/*.md") if f"-{role}-" in p.name)
            if (m := re.match(rf"MR {re.escape(role)} ([0-9a-f]{{7,40}})", subject))}
    answered = {h for subject in subjects(box.glob(f"{role}/**/*.md")) if subject.startswith(("merged ", "returned "))
                for h in re.findall(r"\b[0-9a-f]{7,40}\b", subject)}
    answered |= {m[1] for subject in subjects(p for p in box.glob("*/**/*.md") if f"-{role}-" in p.name)
                 if (m := re.match(r"withdraw ([0-9a-f]{7,40})\b", subject))}
    return [(h, subject) for h, subject in sent.items()
            if not any(a.startswith(h) or h.startswith(a) for a in answered)]


def cmd_squash(ns: argparse.Namespace) -> None:
    """Against one resolved main, so a merge landing in between makes it refuse instead of reverting what landed."""
    need_who_why()
    if git("status", "--porcelain", "--untracked-files=no").strip():
        sys.exit("task: commit or stash your changes first (a WIP commit is fine; it gets squashed)")
    log_start()
    head = git("rev-parse", "HEAD").strip()
    for sent, subject in pending_requests(RUN_INFO["who"]):
        if not subprocess.run(["git", "merge-base", "--is-ancestor", sent, "HEAD"], cwd=ROOT,
                              capture_output=True).returncode:
            sys.exit(f"task: your branch holds the commit of your pending request ({subject}); wait for 'merged' "
                     "or 'returned', or mail the boss 'withdraw <hash>' to replace it")
    message = Path(ns.message).read_text(encoding="utf-8")
    onto = main_hash()
    allowed = branch_files(onto)
    if subprocess.run(["git", "rebase", onto], cwd=ROOT).returncode:
        sys.exit("task: the rebase stopped on a conflict: resolve it, `git add` the files, then "
                 "`GIT_EDITOR=true git rebase --continue` (plain --continue opens an editor), then run squash again")
    try:
        git("reset", "--soft", onto)
        if not subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT).returncode:
            raise SystemExit("task: nothing left to squash: all of it is on main already")
        subprocess.run(["git", "commit", "-q", "-F", "-"], cwd=ROOT, input=message, text=True, encoding="utf-8",
                       check=True)
        if problems := base_problems(ns.deletes, ns.restores, allowed, onto):
            raise SystemExit("task: refused, the squashed commit would:\n  " + "\n  ".join(problems))
    except BaseException:
        git("reset", "-q", "--hard", head, check=False)
        print(f"task: your branch is back at {head[:7]}", flush=True)
        raise
    print(f"task: squashed to {git('rev-parse', '--short', 'HEAD').strip()} on main {onto[:7]}:\n"
          f"{git('diff', '--stat', onto, 'HEAD')}")


def cmd_check(ns: argparse.Namespace) -> None:
    """Reads this tree's config now, not the cached one: `prepare` checks out another commit first."""
    need_who_why()
    if problems := base_problems(ns.deletes, ns.restores):
        sys.exit("task: looks squashed on a stale base:\n  " + "\n  ".join(problems))
    checks = load_config(ROOT / CONFIG)["checks"]
    if not checks:
        sys.exit(f"task: no checks in {ROOT / CONFIG} (\"checks\"): add the build, test and lint commands")
    for c in checks:
        run_command(c, name=c.get("name", ""))
    cmd_todos(argparse.Namespace(action="list"))
    print("task: check passed", flush=True)


# A passed `check` (not a task whose name starts with "check") in an `--at` tree, in log_run's field order.
CHECK_DONE = re.compile(r"\S+ \S+  done +who=\S*  worktree=at-\S+  head=(\S+)  dirty=no  task='check(?:'| )")


def checked_clean(commit: str) -> str:
    """Only `--at` runs count: in a throwaway tree, nothing untracked helped the check pass."""
    path = main_checkout() / ".zerg" / "team" / "runs.log"
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines() if path.exists() else []
    return next((line for line in reversed(lines) if (m := CHECK_DONE.match(line)) and m[1] == commit[:9]), "")


def cmd_prepare(ns: argparse.Namespace) -> None:
    need_who_why()
    if ROOT == main_checkout():
        run_at(ns.hash, sys.argv[1:])
    # the rest checks out and rebases in place, so only in a throwaway tree run_at made, never a session's worktree
    temp = (main_checkout() / ".zerg" / "temp").resolve()
    if not ROOT.name.startswith("at-") or ROOT.parent.parent.resolve() != temp:
        sys.exit(f"task: prepare runs in the main checkout ({main_checkout()}), which runs it in a throwaway tree")
    sent = git("rev-parse", "--verify", f"{ns.hash}^{{commit}}").strip()
    main = main_hash()
    on_top = not subprocess.run(["git", "merge-base", "--is-ancestor", main, sent], cwd=ROOT).returncode
    count = int(git("rev-list", "--count", f"{main}..{sent}").strip() or 0) if on_top else 0
    merge = f"task.py merge {{}} --from {ns.from_role}:{sent[:9]} --who boss --why \"...\""
    if git("diff", "--name-only", f"{sent}^", sent, "--", CONFIG.as_posix()).strip():
        print(f"task: {sent[:9]} changes {CONFIG.as_posix()}, which sets the checks it is checked with: read that part "
              "of the diff before you merge", flush=True)
    if on_top and count > 1:
        sys.exit(f"task: {sent[:9]} is {count} commits: mail {ns.from_role} \"returned {sent[:9]}: squash it\"")
    if on_top and count == 1 and (line := checked_clean(sent)):
        print(f"task: {sent[:9]} is one commit on main {main[:9]}, checked by {ns.from_role} ({line[:19]}). "
              f"Merge it:\n  {merge.format(sent[:9])}")
        return
    git("checkout", "-q", "--detach", sent)
    if not on_top and subprocess.run(["git", "rebase", main], cwd=ROOT, capture_output=True).returncode:
        files = ", ".join(git("diff", "--name-only", "--diff-filter=U").split()) or "?"
        git("rebase", "--abort", check=False)
        sys.exit(f"task: {sent[:9]} conflicts with main {main[:9]} in {files}: mail {ns.from_role} \"returned "
                 f"{sent[:9]}: conflicts with main in {files}; squash on main and send it again\"")
    head = git("rev-parse", "HEAD").strip()
    if int(git("rev-list", "--count", f"{main}..{head}").strip() or 0) != 1:
        sys.exit(f"task: {sent[:9]} is not one commit on main: mail {ns.from_role} \"returned {sent[:9]}: squash it\"")
    # what the sender's commit deletes or changes on purpose stays allowed after the rebase
    status = [row.split("\t", 1) for row in git("diff", "--name-status", "--no-renames", f"{sent}^", sent).splitlines()]
    cmd_check(argparse.Namespace(deletes=[f for st, f in status if st == "D"],
                                 restores=[f for st, f in status if st == "M"]))
    print(f"task: {head[:9]} on main {main[:9]}: {'checked again' if head == sent else f'rebased from {sent[:9]}'}, "
          f"checks passed. Merge it:\n  {merge.format(head[:9])}")


def cmd_merge(ns: argparse.Namespace) -> None:
    """The guards before the fast-forward must never be skipped."""
    need_who_why()
    role, _, sent = ns.from_spec.partition(":")
    if not (role and sent):
        sys.exit("task: merge needs --from ROLE:SENT-HASH (the sender and the hash it sent)")
    role = check_role(role)  # lower case, as its inbox is named; the "merged" mail goes there
    if ROOT != main_checkout():
        sys.exit("task: merge runs only in the main checkout")
    if git("symbolic-ref", "--short", "HEAD", check=False).strip() != "main":
        sys.exit("task: the main checkout is not on main (`git checkout main` first)")
    if git("status", "--porcelain", "--untracked-files=no").strip():
        sys.exit("task: the main checkout has uncommitted changes; commit them first")
    if subprocess.run(["git", "rev-parse", "--verify", "-q", f"{ns.hash}^{{commit}}"], cwd=ROOT,
                      capture_output=True).returncode:
        sys.exit(f"task: {ns.hash} is not a commit")
    if subprocess.run(["git", "merge-base", "--is-ancestor", main_hash(), ns.hash], cwd=ROOT).returncode:
        sys.exit(f"task: {ns.hash} is not a fast-forward of main: `task.py prepare` rebases and checks it")
    log_start()
    git("merge", "--ff-only", "-q", ns.hash)
    short = main_hash()[:9]
    write_journal(f"merged {ns.hash[:9]} from {role} {sent[:9]}, main = {short} ({RUN_INFO['why']})")
    subprocess.run([sys.executable, str(Path(__file__).with_name("mail.py")), "send", "--from", "boss", "--to", role,
                    f"merged {ns.hash[:9]} from {role} {sent[:9]}, main = {short}"],
                   input=f"Rebase: git rebase --onto main {sent[:9]}\n", text=True, encoding="utf-8", check=True)
    print(f"task: main = {short}")


def write_journal(line: str) -> None:
    path = main_checkout() / ".zerg" / "team" / "journal.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"- {time.strftime('%Y-%m-%d %H:%M')} {RUN_INFO['who']}: {' '.join(line.split())}\n")


def cmd_journal(ns: argparse.Namespace) -> None:
    if not RUN_INFO["who"]:
        sys.exit("task: journal needs --who ROLE")
    write_journal(ns.line)
    print("task: journaled")


def run_at(at: str, argv: list[str]) -> None:
    commit = git("rev-parse", "--verify", f"{at}^{{commit}}").strip()
    who = next((a.split("=", 1)[1] if "=" in a else argv[i + 1] for i, a in enumerate(argv)
                if a.startswith("--who") and ("=" in a or i + 1 < len(argv))), "")
    who = check_role(who) if who else "unknown"
    tree = main_checkout() / ".zerg" / "temp" / who / f"at-{commit[:9]}-{os.getpid()}"
    git("worktree", "add", "-q", "--detach", str(tree), commit)
    def remove(*_):
        git("worktree", "remove", "--force", str(tree), check=False)
        sys.exit("task: stopped")
    for stop in (signal.SIGTERM, signal.SIGINT):
        signal.signal(stop, remove)
    try:
        code = subprocess.run([sys.executable, os.path.abspath(__file__), *argv], cwd=tree).returncode
    finally:
        git("worktree", "remove", "--force", str(tree), check=False)
    sys.exit(code)


def cmd_audit(ns: argparse.Namespace) -> None:
    """A branch has landed when merging it into base changes nothing, however it was squashed."""
    if not has_commits():
        sys.exit("task: nothing committed yet, so nothing to audit")
    base = git("rev-parse", "--verify", f"{ns.base}^{{commit}}").strip()
    base_tree = git("rev-parse", f"{base}^{{tree}}").strip()
    if subprocess.run(["git", "merge-tree", "--write-tree", base, base], cwd=ROOT, capture_output=True).returncode:
        sys.exit("task: audit needs git 2.38 or later (git merge-tree --write-tree)")
    rows = []
    for branch in git("for-each-ref", "--format=%(refname:short)", "refs/heads").split():
        if branch == ns.base:
            continue
        ahead = [line[2:] for line in git("cherry", "-v", base, f"refs/heads/{branch}").splitlines()
                 if line.startswith("+")]
        merged_tree = git("merge-tree", "--write-tree", base, f"refs/heads/{branch}", check=False).split("\n", 1)[0]
        landed = merged_tree.strip() == base_tree
        commits = ", ".join(f"{c[:9]} {c[41:]}"[:60] for c in ahead) or "none"
        rows.append(f"| {branch} | {commits} | {'landed' if landed else 'NOT LANDED'} |")
    print(f"Audit {time.strftime('%Y-%m-%d %H:%M')}, {ns.base} {base[:7]}.\n")
    if rows:
        print("| Branch | Commits not on base | On base? |\n|---|---|---|\n" + "\n".join(rows))
    else:
        print(f"Every branch is on {ns.base}: nothing unmerged.")
    dirty = []
    for tree in worktree_paths():
        if tree.exists() and (files := git("status", "--porcelain", cwd=tree).splitlines()):
            dirty.append(f"{tree.name} ({len(files)} files)")
    print(f"\nUncommitted: {', '.join(dirty) or 'none'}")


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--who", default="", help="your session's mail role, for .zerg/team/runs.log")
    common.add_argument("--why", default="", help="what this run checks, for .zerg/team/runs.log")
    sub = parser.add_subparsers(dest="task")
    p = sub.add_parser("run", parents=[common])
    p.add_argument("--slot", required=True)
    p.add_argument("--timeout", type=float, default=900)
    p.set_defaults(fn=cmd_run)
    sub.add_parser("slots", parents=[common]).set_defaults(fn=cmd_slots)
    p = sub.add_parser("usertest", parents=[common])
    p.add_argument("minutes", nargs="?", type=float, default=120)
    p.add_argument("--for", dest="for_role", help="the one role whose runs still start (a quiet window)")
    p.add_argument("--slots", help="comma-separated slots to keep free (default: all)")
    p.add_argument("--no-wait", action="store_true", help="don't wait for running jobs to finish")
    p.add_argument("--end", action="store_true", help="the user is done testing")
    p.set_defaults(fn=cmd_usertest)
    p = sub.add_parser("todos", parents=[common])
    p.add_argument("action", nargs="?", choices=["list", "next"], default="list")
    p.set_defaults(fn=cmd_todos)
    p = sub.add_parser("squash", parents=[common])
    p.add_argument("-m", "--message", required=True, help="a file holding the commit message")
    p.add_argument("--deletes", action="append", default=[], help="a file the commit deletes on purpose")
    p.add_argument("--restores", action="append", default=[], help="a file the commit sets back on purpose")
    p.set_defaults(fn=cmd_squash)
    p = sub.add_parser("check", parents=[common])
    p.add_argument("--deletes", action="append", default=[], help="a file the commit deletes on purpose")
    p.add_argument("--restores", action="append", default=[], help="a file the commit sets back on purpose")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("prepare", parents=[common])
    p.add_argument("hash")
    p.add_argument("--from", dest="from_role", required=True, help="the role that sent the merge request")
    p.set_defaults(fn=cmd_prepare)
    p = sub.add_parser("merge", parents=[common])
    p.add_argument("hash")
    p.add_argument("--from", dest="from_spec", required=True, help="ROLE:SENT-HASH of the merge request")
    p.set_defaults(fn=cmd_merge)
    p = sub.add_parser("journal", parents=[common])
    p.add_argument("line")
    p.set_defaults(fn=cmd_journal)
    p = sub.add_parser("open", parents=[common])
    p.add_argument("role")
    p.add_argument("--title", help="a new session's name, such as \"Relay API\"")
    p.add_argument("--autocompact", help="a new session's auto-compact window (default 500k; reviewer 300k)")
    p.set_defaults(fn=cmd_open)
    for name, c in team_config()["tasks"].items():
        p = sub.add_parser(name, parents=[common], help=" ".join(c["run"])[:60])
        p.add_argument("--timeout", type=float)
        p.set_defaults(fn=cmd_task)
    p = sub.add_parser("audit", parents=[common])
    p.add_argument("base", nargs="?", default="main")
    p.set_defaults(fn=cmd_audit)
    team_config()  # not a zerg project: fails here, naming the path
    own = sys.argv[1:]
    if own[:1] == ["--at"]:
        if len(own) < 3:
            sys.exit("task: --at HASH TASK ...")
        run_at(own[1], own[2:])
    passed = own[own.index("--") + 1:] if "--" in own else []
    own = own[:own.index("--")] if "--" in own else own
    ns = parser.parse_args(own)
    if not ns.task:
        parser.print_help()
        return
    ns.args = passed
    argv = [a for i, a in enumerate(own)
            if not a.startswith(("--who", "--why")) and (i == 0 or own[i - 1] not in ("--who", "--why"))]
    RUN_INFO.update(who=check_role(ns.who) if ns.who.strip() else "", why=" ".join(ns.why.split()),
                    command=" ".join(argv + passed)[:200])
    try:
        ns.fn(ns)
    except SystemExit as e:
        log_end("" if e.code in (None, 0) else repr(str(e.code))[:200])
        raise
    except BaseException as e:
        log_end(type(e).__name__)
        raise
    log_end()


if __name__ == "__main__":
    main()
