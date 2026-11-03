"""Sets a git project up for a zerg team. Never overwrites an existing file.

    zerg init PROJECT_DIR --name NAME

Creates the boss and Reviewer sessions; the boss creates the others from the Product areas in etc/zerg/project.md with
`task.py open ROLE --title ...` when their time comes. The checked-out branch must be main.

Writes the plugin's templates/project/ files, creates etc/notes, etc/todos and etc/plans, adds /.zerg/,
.claude/worktrees/ and __pycache__/ to .gitignore, runs `task.py open` for boss and reviewer, and counts the
<<FILL: ...>> markers left for /zerg:setup.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SKILL = Path(os.path.abspath(__file__)).parents[1]
STARTERS = SKILL / "templates" / "project"
IGNORES = ["/.zerg/", ".claude/worktrees/", "__pycache__/"]
TRACKED = ["etc/zerg/config.json", "etc/zerg/project.md"]
MARKER = "<<FILL"
KEEP = ["etc/notes/.gitkeep", "etc/todos/.gitkeep", "etc/plans/.gitkeep"]


def write_new(path: Path, data: bytes) -> bool:
    if path.exists():
        print(f"init: kept existing {path}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    print(f"init: wrote {path}")
    return True


def add_ignores(path: Path, lines: list[str]) -> None:
    have = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []
    if missing := [line for line in lines if line not in have]:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(("\n" if have and have[-1] else "") + "\n".join(missing) + "\n")
        print(f"init: {path} += {' '.join(missing)}")


def report_missing_rules(path: Path, starter: dict) -> None:
    try:
        have = set(json.loads(path.read_text(encoding="utf-8")).get("permissions", {}).get("allow", []))
    except (OSError, ValueError, AttributeError):
        have = set()
    if missing := [rule for rule in starter["permissions"]["allow"] if rule not in have]:
        print(f"init: add these to permissions.allow in {path}: {json.dumps(missing)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project")
    parser.add_argument("--name", required=True, help="the project's name, used in session names")
    ns = parser.parse_args()
    root = Path(ns.project).resolve()
    if not root.is_dir():
        sys.exit(f"init: {root} does not exist")
    if subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=root, capture_output=True).returncode:
        sys.exit(f"init: {root} is not a git repository (git init it first)")
    branch = subprocess.run(["git", "symbolic-ref", "--short", "HEAD"], cwd=root, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if branch.stdout.strip() != "main":
        sys.exit(f"init: the workflow needs the checked-out branch to be main, not {branch.stdout.strip() or '?'!r}"
                 " (rename it with git branch -m main)")
    # the plugin version that set the project up, for a future upgrade of its files
    version = json.loads((SKILL / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["version"]
    values = {"PROJECT": ns.name, "VERSION": version}
    for source in sorted(p for p in STARTERS.rglob("*") if p.is_file() and p.name not in (".DS_Store", "Thumbs.db")):
        relative = source.relative_to(STARTERS)
        text = source.read_text(encoding="utf-8")
        for key, value in values.items():
            # escaped in .json files, so a name with a quote or a backslash keeps them valid
            text = text.replace("{{" + key + "}}", json.dumps(value)[1:-1] if source.suffix == ".json" else value)
        if not write_new(root / relative, text.encode("utf-8")) and relative.as_posix() == ".claude/settings.json":
            report_missing_rules(root / relative, json.loads(text))
    for keep in KEEP:
        folder = (root / keep).parent
        folder.mkdir(parents=True, exist_ok=True)
        if not any(folder.iterdir()):
            write_new(root / keep, b"")
    add_ignores(root / ".gitignore", IGNORES)
    (root / ".zerg" / "mail").mkdir(parents=True, exist_ok=True)
    # -v also prints a matching negation (!...), which un-ignores the file rather than hiding it
    committed = [*TRACKED, ".claude/settings.json", *KEEP]
    hidden = subprocess.run(["git", "check-ignore", "-v", *committed], cwd=root, capture_output=True, text=True,
                            encoding="utf-8", errors="replace").stdout
    for line in hidden.splitlines():
        rule, _, path = line.partition("\t")
        if not re.search(r":\d+:!", rule):  # source:line:pattern, the source may hold a drive letter
            print(f"init: {path} is ignored by {rule}: un-ignore it, or worktrees won't have it")

    for role in ("boss", "reviewer"):
        if (root / ".zerg" / "state" / f"{role}.md").exists():
            print(f"init: kept existing .zerg/state/{role}.md")
            continue
        proc = subprocess.run([sys.executable, str(SKILL / "scripts" / "task.py"), "open", role, "--title",
                               f"{ns.name} {role.capitalize()}"], cwd=root, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
        out = (proc.stdout + proc.stderr).strip()
        # only the "created" line: spawn's inputs come later (`task.py open boss`), once the focus is filled in
        print(out if proc.returncode else out.splitlines()[0])
        if proc.returncode:
            sys.exit(f"init: task.py open {role} failed")

    # only where the templates put markers: .zerg/data and .zerg/temp may hold whole repos
    filled = [root / name for name in TRACKED] + sorted((root / ".zerg" / "state").glob("*.md"))
    left = [f"{path.relative_to(root).as_posix()}:{i}" for path in filled if path.exists()
            for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1) if MARKER in line]
    print(f"init: {len(left)} {MARKER}: ...>> markers to fill: grep -n '{MARKER}' etc/zerg/* .zerg/state/*")
    print("init: done. Next: the rest of /zerg:setup.")


if __name__ == "__main__":
    main()
