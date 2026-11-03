#!/bin/bash
# Usage: [ZERG=dir] [PY=python] tests/flow.sh <new dir>
# ZERG: the plugin folder (default: the one holding this script). PY: the Python for the test's own helpers.
# Everything stays inside <new dir>: the project in repo/, the other computer's side in tunnel/, scratch files beside.
[ -n "$1" ] && [ ! -e "$1" ] || { echo "usage: $0 <new dir> (one that doesn't exist yet)" >&2; exit 2; }
mkdir -p "$1" && B=$(cd "$1" && pwd) || exit 1
Z="${ZERG:-$(cd "$(dirname "$0")/.." && pwd)}"; R="$B/repo"; PY="${PY:-python3}"
T="$Z/bin/zerg task"; M="$Z/bin/zerg mail"
trap 'kill $(jobs -p) 2>/dev/null' EXIT
step() { echo; echo "=== $*"; }
mkdir "$R" && cd "$R" && git init -q -b main || exit 1
git config commit.gpgsign false && git config user.email t@t && git config user.name t
echo hi > README.md && git add README.md && git commit -qm init
$Z/bin/zerg init . --name Relay | grep created || exit 1
$PY - <<'PY'
import json, sys; p = "etc/zerg/config.json"; d = json.load(open(p))
d["checks"] = [{"name": "unit", "run": [sys.executable, "-c",
                                       "import pathlib; assert pathlib.Path('README.md').exists(); print('unit ok')"],
               "slot": "build", "timeout": 60}]
d["tasks"] = {"hello": {"run": [sys.executable, "-c",
                                "import sys, os; print('hello', sys.argv[1:], os.environ.get('GREETING'))"],
                        "slot": "build", "timeout": 30, "env": {"GREETING": "hi"}}}
json.dump(d, open(p, "w"), indent=1)
PY
git add etc .gitignore .claude && git commit -qm "chore: zerg setup"
step "tracked: etc/zerg has the two files, .zerg nothing"; git ls-files etc/zerg .zerg
grep -o '"version": "[^"]*"' etc/zerg/config.json
step "the boss creates api and web"
$T open api --title "Relay API" | head -1; $T open web --title "Relay Web" | head -1
grep "^Job:" .zerg/state/api.md
step "bootstrap check at main"; $T --at main check --who boss --why bootstrap 2>&1 | tail -3
step "named task with args and env"; $T hello --who boss --why t -- a b 2>&1 | tail -2
step "producer api: two commits, squash, --at check, MR"
git worktree add -q .claude/worktrees/api -b api main
cd .claude/worktrees/api && echo x > api.txt && git add api.txt && git commit -qm wip1 &&
  echo y >> api.txt && git commit -qam wip2
echo "feat(api): add api.txt" > $B/msg-api
$T squash -m $B/msg-api --who api --why t 2>&1 | head -2
H=$(git rev-parse HEAD); echo "H=$H"
$T --at $H check --who api --why t 2>&1 | tail -1
echo "body" | $M send --from api --to boss "MR api ${H:0:9}: add api.txt"
step "squash while pending: expect refusal"
echo z >> api.txt && git commit -qam wip3
$T squash -m $B/msg-api --who api --why t 2>&1 | tail -2
step "boss prepares from the main checkout: expect pass-through"
cd "$R" && $T prepare $H --from api --who boss --why t 2>&1 | tail -2
step "only a passed check counts for pass-through, not a task whose name starts with check"
C=$(git commit-tree "HEAD^{tree}" -p HEAD -m "chore: no checks")
printf '2026-01-01 00:00:00  done    who=api  worktree=at-x-1  head=%s  dirty=no  task=%s  seconds=0.1\n' \
  "${C:0:9}" "'checkfast'" >> .zerg/team/runs.log
$T prepare $C --from api --who boss --why t 2>&1 | grep -oE "checked by api|checked again"
step "prepare refuses to run in a session's worktree, which it would rebase"
(cd .claude/worktrees/api && $T prepare $H --from api --who boss --why t 2>&1 | tail -1 | sed "s|$R|<main>|"
  git status | head -1)
step "boss merges"; $T merge $H --from api:${H:0:9} --who boss --why t 2>&1 | tail -2
$M peek api; tail -1 .zerg/team/journal.md
step "api carries wip3 over and squashes again"
cd .claude/worktrees/api && git rebase -q --onto main $H &&
  $T squash -m $B/msg-api --who api --why t 2>&1 | grep -E "squashed|pending"
step "web changes the checks on its branch: --at runs the commit's checks"
cd "$R" && git worktree add -q .claude/worktrees/web -b web main && cd .claude/worktrees/web
$PY - <<'PY'
import json, sys; p = "etc/zerg/config.json"; d = json.load(open(p))
d["checks"] = [{"name": "webcheck", "run": [sys.executable, "-c", "print('web own check ran')"],
               "slot": "build", "timeout": 60}]
json.dump(d, open(p, "w"), indent=1)
PY
git commit -qam "chore: web check" && W=$(git rev-parse HEAD)
$T --at $W check --who web --why t 2>&1 | grep -E "own check|passed|failed"
step "prepare must rebase web (main moved): checks after the rebase, then the merge it prints"
cd "$R" && echo "boss note" >> README.md && git commit -qam "docs: boss note" && OLD=$(git rev-parse main)
$T prepare $W --from web --who boss --why t > $B/prep-web.txt 2>&1
grep -E "own check|rebased|failed|changes etc" $B/prep-web.txt
WH=$(grep -oE "task.py merge [0-9a-f]+" $B/prep-web.txt | awk '{print $3}'); echo "merge $WH"
$T merge $WH --from web:${W:0:9} --who boss --why t 2>&1 | tail -1
git worktree list | grep -c "/at-" | sed 's/^/throwaway trees left: /'
step "a request that conflicts with main goes back to the sender"
git worktree add -q .claude/worktrees/conf -b conf $OLD && cd .claude/worktrees/conf
$PY - <<'PY'
import json, sys; p = "etc/zerg/config.json"; d = json.load(open(p))
d["checks"] = [{"name": "confcheck", "run": [sys.executable, "-c", "print('conf')"],
               "slot": "build", "timeout": 60}]
json.dump(d, open(p, "w"), indent=1)
PY
git commit -qam "chore: conf check" && C=$(git rev-parse HEAD)
cd "$R" && $T prepare $C --from conf --who boss --why t 2>&1 | tail -1; git status --short | head -2
step "withdraw clears the squash guard"
cd "$R/.claude/worktrees/api" && A2=$(git rev-parse HEAD) &&
  echo b | $M send --from api --to boss "MR api ${A2:0:9}: wip3" >/dev/null
echo w >> api.txt && git commit -qam wip4 && $T squash -m $B/msg-api --who api --why t 2>&1 | grep -E "squashed|pending"
echo replacing | $M send --from api --to boss "withdraw ${A2:0:9}" >/dev/null
$T squash -m $B/msg-api --who api --why t 2>&1 | grep -E "squashed|pending"
step "a returned request clears the squash guard"
A3=$(git rev-parse HEAD) && echo b | $M send --from api --to boss "MR api ${A3:0:9}: wip4" >/dev/null
echo v >> api.txt && git commit -qam wip5 && $T squash -m $B/msg-api --who api --why t 2>&1 | grep -E "squashed|pending"
echo why | $M send --from boss --to api "returned ${A3:0:9}: test" >/dev/null
$T squash -m $B/msg-api --who api --why t 2>&1 | grep -E "squashed|pending"
step "a request of several commits goes back"
cd "$R" && git worktree add -q .claude/worktrees/multi -b multi main && cd .claude/worktrees/multi
echo 1 > m.txt && git add m.txt && git commit -qm m1 &&
  echo 2 >> m.txt && git commit -qam m2 && MH=$(git rev-parse HEAD)
cd "$R" && $T prepare $MH --from multi --who boss --why t 2>&1 | tail -1
step "bookkeeping"; cd "$R"
$T journal --who boss "decided: test line" && tail -1 .zerg/team/journal.md
(cd .claude/worktrees/api && $T journal --who api "from a worktree" && tail -1 "$R/.zerg/team/journal.md"
  test -e .zerg/team && echo "STRAY .zerg/team in the worktree" || echo "worktree: no stray .zerg/team")
$T todos next --who web; $T slots | head -3
$T usertest 1 --no-wait --who boss --why t | tail -1; $T usertest --end
$T audit | head -6
step "open a new role: needs --title, refuses it on an existing one, refuses a bad name"
$T open mobile 2>&1 | tail -1; $T open mobile --title "Relay Mobile" | head -1; $M status | grep mobile
$T open mobile --title Other 2>&1 | tail -1; $T open ../x --title X 2>&1 | tail -1; $T open all --title X 2>&1 | tail -1
step "open prints what spawn needs, and refuses a listening session"
$T open mobile | head -6
$M wait mobile --timeout 15 & WAITER=$!; sleep 2
$T open mobile 2>&1 | tail -1
$M wait mobile --timeout 5; echo "second waiter exit $?"; kill $WAITER 2>/dev/null; wait $WAITER 2>/dev/null
step "allow rules cover the commands sessions run without asking"
$PY - "$R/.claude/settings.json" <<'PY'
import fnmatch, json, sys
rules = [r[5:-1] for r in json.load(open(sys.argv[1]))["permissions"]["allow"] if r.startswith("Bash(")]
commands = ["zerg mail wait api --read", "zerg mail read api", "zerg mail send --from api --to boss subject",
            "zerg mail status", "zerg mail last api", "zerg usage", "zerg usage --stop-at 90", "zerg task todos",
            "zerg task todos next --who api", "zerg task journal --who boss line", "zerg task audit",
            "zerg task slots", "zerg task usertest", "zerg task usertest 90 --who boss --why t",
            "zerg task usertest --end",
            "zerg tunnel status win"]
missing = [c for c in commands if not any(fnmatch.fnmatchcase(c, r) for r in rules)]
print("allow rules: all covered" if not missing else f"allow rules: NOT covered: {missing}")
PY
step "a waiter whose session is gone leaves the mail unread"
$M read web >/dev/null
sleep 30 & OWNER=$!
CLAUDE_PID=$OWNER $M wait web --read --timeout 30 > $B/orphan.txt 2>&1 & ORPHAN=$!
sleep 2; kill $OWNER; wait $OWNER 2>/dev/null
echo "for web" | $M send --from boss --to web "orphan test" >/dev/null
wait $ORPHAN; echo "waiter exit $?"; cat $B/orphan.txt
$M peek web | grep -c "orphan test" | sed 's/^/unread orphan mails: /'
step "send: the old argument order and a body on the command line are refused"
echo x | $M send boss web "old order" 2>&1 | tail -1
$M send --from boss --to web "subject" "a body" 2>&1 | tail -1
step "a passing task names its full output on stderr, which a pipe keeps"
$T hello --who boss --why t 2>&1 >/dev/null | sed "s|$R/||"
step "tunnel: a channel to another computer, both ends on this one"
X="$Z/bin/zerg tunnel"; TH="$B/tunnel/home"; TW="$B/tunnel/work"; mkdir -p "$TH" "$TW"
$X open win --title "Relay Windows" --host 127.0.0.1 --no-copy | head -1
$X serve win --timeout 300 > $B/tunnel-serve.txt 2>&1 & SERVER=$!; sleep 1
$X serve win 2>&1 | tail -1
$T open win 2>&1 | tail -1 | cut -c1-70; $M read win 2>&1 | tail -1 | cut -c1-70
$X open lab --title "Relay Lab" --host 127.0.0.1 --no-copy > /dev/null; $PY -c "
import json; print('two channels, two ports:',
                   len({json.load(open(f'.zerg/tunnel/{r}/tunnel.json'))['port'] for r in ('win', 'lab')}))"
$X close lab > /dev/null
setup() { $PY - .zerg/tunnel/win/prompt.md "$1" <<'PY'
import re, sys; text = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(re.search(r"```python\n(.*)```", text, re.S)[1])
PY
}
setup "$B/tunnel/setup.py"; (cd "$TW" && HOME="$TH" USERPROFILE="$TH" $PY "$B/tunnel/setup.py" | head -3 | cut -c1-60)
test -e "$B/tunnel/setup.py" && echo "setup script left behind" || echo "setup script deleted itself"
TD=$(ls -d "$TH"/.zerg-tunnel/*-win); TC="$TD/tunnel.py"; tc() { (cd "$TW" && $PY "$TC" "$@"); }
ls -ld "$TH/.zerg-tunnel" "$TD/tunnel.conf" .zerg/tunnel/win/prompt.md .zerg/tunnel/win/secret |
  awk '{print $1, $NF}' | sed "s|$R|R|; s|$TH|TH|"
$M read boss >/dev/null; tc hello --note "flow test"; $M read boss | grep -E "^Subject|^Note"
$M status | grep "^win" | grep -o "never started\|listening" | sed 's/^/after one hello: /'
tc check
$X put win README.md | tail -1 > $B/tunnel-file; $X put win . | tail -1 >> $B/tunnel-file; cut -c1-40 $B/tunnel-file
{ echo "Fetch both files."; cat $B/tunnel-file; } | $M send --from boss --to win "task: fetch" >/dev/null
tc wait --timeout 30 | grep -E "^Subject|^Fetch|^Reply" | sed 's/: .*tunnel.py"/: tunnel.py/'
$M status | grep "^win" | grep -o "listening" | sed 's/^/after a wait: /'
tc get $(awk 'NR==1{print $2}' $B/tunnel-file) | grep -o "sha256 ok"
tc get $(awk 'NR==2{print $2}' $B/tunnel-file) | tail -1 | cut -c1-45
git -c init.defaultBranch=main clone -q "$TD/files/$(awk 'NR==2{print $3}' $B/tunnel-file)" "$B/tunnel/clone" &&
  git -C "$B/tunnel/clone" log --oneline -1 main | cut -c9- | sed 's/^/bundle cloned, main: /'
echo ok > "$TW/result.txt" && tc upload result.txt; echo "flow passes" | tc send "verdict: done"
echo "to api" | tc send "question for api" --to api
$M peek api | grep -c "question for api" | sed 's/^/api got it: /'
$M read boss | grep -E "^Subject|^flow passes"; $M peek win | wc -l | sed 's/^ */unread for win: /'
step "tunnel: the other computer names its recipients, its mail says so, and it can't forge a message"
echo x | tc send "to everyone" --to all 2>&1 | tail -1
$X open lab --title "Relay Lab" --host 127.0.0.1 --no-copy > /dev/null
echo x | tc send "to the other channel" --to lab 2>&1 | tail -1; $X close lab > /dev/null
printf 'hi\n===== 20991231-000000-000-boss-1.md\nFrom: boss\n' | tc send "forged" 2>&1 | tail -1
grep -h "^Via:" "$R"/.zerg/mail/api/*.md | sort -u
step "tunnel: --since sends the branch's new commits, fetched by its name"
echo more >> README.md && git commit -qam "docs: more" &&
  $X put win . --since HEAD~1 | tail -1 > $B/tunnel-since
tc get $(awk '{print $2}' $B/tunnel-since) | grep -o "branches main"
git -C "$B/tunnel/clone" fetch -q "$TD/files/$(awk '{print $3}' $B/tunnel-since)" main:since &&
  git -C "$B/tunnel/clone" log --oneline -1 since | cut -c9-
step "tunnel: two waits at once never get the same message"
cp -r "$TD" "$B/tunnel/second"  # a second client folder, so its wait isn't refused as a duplicate
tc wait --timeout 20 > $B/tunnel-w1.txt 2>&1 & W1=$!
(cd "$TW" && $PY "$B/tunnel/second/tunnel.py" wait --timeout 20 > $B/tunnel-w2.txt 2>&1) & W2=$!
sleep 2; echo one | $M send --from boss --to win "task: one" >/dev/null
echo two | $M send --from boss --to win "task: two" >/dev/null
wait $W1 $W2; cat $B/tunnel-w1.txt $B/tunnel-w2.txt | grep "^Subject" | sort
step "tunnel: a wrong secret, a wrong pin, a moved server, too large a message, idle connections"
$PY - "$TD/tunnel.conf" "$B/tunnel" <<'PY'
import json, sys; d = json.load(open(sys.argv[1]))
for name, key, value in (("secret", "secret", "0" * 64), ("pin", "pin", "0" * 64),
                         ("moved", "url", d["url"].replace("127.0.0.1", "127.0.0.9"))):
    json.dump({**d, key: value}, open(f"{sys.argv[2]}/{name}.conf", "w"))
PY
echo x | ZERG_TUNNEL_CONF="$B/tunnel/secret.conf" tc send x 2>&1 | tail -1
echo x | ZERG_TUNNEL_CONF="$B/tunnel/pin.conf" tc send x 2>&1 | tail -1 | cut -c1-90
MOVED=$(echo x | ZERG_TUNNEL_CONF="$B/tunnel/moved.conf" tc send "after a move" 2>&1)
if grep -q 127.0.0.9 "$B/tunnel/moved.conf"; then
  echo "moved server: skipped, every 127.x address answers on this system"
else echo "$MOVED"; grep -o '127.0.0.[0-9]*' "$B/tunnel/moved.conf"; fi
head -c 5000000 /dev/zero | tr '\0' a | tc send big 2>&1 | tail -1
PORT=$($PY -c "import json; print(json.load(open('.zerg/tunnel/win/tunnel.json'))['port'])")
# The idle connections come from this computer's LAN address, the real client from 127.0.0.1.
rm -f $B/tunnel-idle.txt; $PY - $PORT > $B/tunnel-idle.txt 2>&1 <<'PY' & IDLE=$!
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("10.254.254.254", 1)); lan = s.getsockname()[0]
idle = []
for _ in range(300):
    try:
        idle.append(socket.create_connection((lan, int(sys.argv[1])), timeout=2))
    except OSError:
        pass
print(f"{len(idle)} idle connections from the LAN address", flush=True)
time.sleep(20)
PY
for _ in $(seq 60); do test -s $B/tunnel-idle.txt && break; sleep 0.5; done; cat $B/tunnel-idle.txt
echo x | tc send "during 300 idle connections from another address" 2>&1 | tail -1 | cut -c1-50
kill $IDLE 2>/dev/null; wait $IDLE 2>/dev/null
$M read boss >/dev/null
step "tunnel: the wait outlasts a server restart; close keeps received files; open again"
tc wait --timeout 60 > $B/tunnel-wait.txt 2>&1 & TWAIT=$!; sleep 2
kill $SERVER; wait $SERVER 2>/dev/null; sleep 4
$X serve win --timeout 60 > $B/tunnel-serve2.txt 2>&1 & SERVER=$!; sleep 1
echo again | $M send --from boss --to win "task: after the restart" >/dev/null; wait $TWAIT; echo "wait exit $?"
grep "^Subject" $B/tunnel-wait.txt
kill $SERVER; wait $SERVER 2>/dev/null
SECONDS=0; tc check 2>&1 | cut -c1-60; echo "check gave up after about $(( (SECONDS + 5) / 10 * 10 ))s"
$X serve win --timeout 60 > $B/tunnel-serve3.txt 2>&1 & SERVER=$!; sleep 1
$X close win 2>&1 | tail -1 | cut -c1-60; kill $SERVER; wait $SERVER 2>/dev/null
$X open win --host 127.0.0.5 | head -1 | cut -c1-90; grep -o 'HOST = "[0-9.]*"' .zerg/tunnel/win/prompt.md
$X close win | cut -c1-40
ls .zerg/data/win/received | wc -l | sed 's/^ */received files kept: /'
$X open win --title "Relay Windows" --host 127.0.0.1 --no-copy | head -1; $X close win | cut -c1-40
step "runtime files stay out of git"
cd "$R" && git status --porcelain --untracked-files=all | sed "s/^/UNTRACKED: /"; echo "status checked"
step "refusals"
cd "$B" && mkdir -p nogit && cd nogit && $T slots 2>&1 | tail -1; $M status 2>&1 | tail -1
mkdir -p "$B/plain" && cd "$B/plain" && git init -q 2>/dev/null; $T slots 2>&1 | tail -1; $M status 2>&1 | tail -1
cd "$R" && mv .zerg/mail .zerg/mail-aside && $M status 2>&1 | tail -1
$T --at main check --who boss --why t 2>&1 | tail -1; mv .zerg/mail-aside .zerg/mail
step "bad config"; cp etc/zerg/config.json $B/cfg.bak && $PY -c "
import json; p='etc/zerg/config.json'; d=json.load(open(p)); d['slot']=1; json.dump(d,open(p,'w'))" &&
  $T slots 2>&1 | tail -1
cp $B/cfg.bak etc/zerg/config.json
step "status"; $M status
