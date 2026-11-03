---
name: tunnel
description: Open a secure channel from the zerg boss to an agent session on another computer on the same network, to send it work, files and repos by mail.
disable-model-invocation: true
---

# A channel to a session on another computer

The other computer gets a mail role of its own, for example `win`. Any session writes to it with
`zerg mail send --from <role> --to win`, and its replies land in the inbox of whoever it answers, the boss's by
default, so the usual mail waiter wakes them. Behind that, a small HTTPS server on this computer carries the mail.
The other side only connects out to it, and needs Python 3.9+ and nothing else: not zerg, not a clone, not Claude
Code.

The user opens the channel by pasting one prompt into a session on the other computer. The prompt says the session
works for the user, and carries a fingerprint of this server's certificate and a secret. Nothing else on the
network can read or fake the channel, so that session treats what you send as the user's own instructions, within
the folder it runs in. Keep it to the task the user agreed to.

## Opening it

1. Tell the user what you need the other computer for and get their OK; that is the task the channel is for.
2. Pick a role name for the computer (`win`, `linux`, `lab`) and a title, "<Project> <Machine>".
3. `zerg tunnel open <role> --title "<title>"` makes the role (inbox, state file), the certificate and the secret,
   saves the prompt in `.zerg/tunnel/<role>/prompt.md` and puts it on this computer's clipboard.
4. `zerg tunnel serve <role>`, alone in its own tracked background call, described as "Channel to <title>". It listens
   on all of this computer's addresses and runs until your session ends (at most 12 hours). When it exits, start it
   again (that asks the user's permission each time). Mail waits for the other side meanwhile, but a wait there that
   gets no answer for a minute stops and tells its user; once the server runs again, ask the user to have it start the
   wait again.
5. Ask the user to open an agent session on the other computer, in the folder it should work in (an empty folder
   or a clone of this repo), and paste the prompt there. It holds the secret: help the user carry it over by a
   private route (a shared clipboard, a USB stick, a note they delete afterwards), not a team chat or email.
   - The first time the server listens, this computer's firewall may ask to allow incoming connections: the user
     allows them (on Windows, for private networks only; a network Windows marks as Public blocks them anyway).
   - `open` names the address the prompt gives. When the other computer reaches this one at another address (a
     VPN can take the default route), `zerg tunnel open <role> --host <ip>` changes it, keeping the secret.
   - With no Python there, that session asks the user to install it.
   - The user may need to confirm twice there: once for the setup script and once for tunnel.py, which its
     permission system judges separately.
6. Its first mail is a hello: OS, Python, tools, its folder and that folder's git state, its harness and whether a
   background command wakes it. Note what matters in `.zerg/state/<role>.md` and plan around it.

## Giving it work

- A task by mail, as to any session: goal, the user's words, what done looks like, and what to send back. It isn't
  a zerg session and doesn't know zerg's rules: say what to run, where, and what to report.
- Files: `zerg tunnel put <role> <path>` stages a copy and prints a `FILE <id> <name> <sha256>` line. Put that line
  in the mail; the other side fetches the file with its hash checked and is told how to unpack it.
  - A git repo goes as a bundle of all its branches and tags (not stashes). When the hello shows a clone of the same
    repo, send only what it lacks: `zerg tunnel put <role> . --since <its commit>` bundles your current branch's
    commits since then (committed work only); tell it to fetch that branch.
  - Any other folder goes as a `.tar.gz`, for example a skill: say where to unpack it. A skills folder outside its
    work folder needs the user's OK there; the hello names Claude Code's when it runs under Claude Code.
- Files it sends back arrive as a mail naming the saved copy in `.zerg/data/<role>/received/`.
- What its session may not do on a request from you (installing system software, changing settings outside its
  folder, credentials) it asks the user in its own chat. When a reply says it waits for the user, tell the user
  which computer and what to answer there.
- A session that said it can't be woken by a background command reads mail only when its user tells it to check:
  tell the user each time you send it something.

## Keeping it up

- `zerg mail status` shows the role as listening while the other side waits for mail, and marks it CHECK when mail
  waits with nobody fetching it. `zerg tunnel status <role>` shows the server and the last wait from the other side.
- A role marked CHECK can't get a direct session message. Check that the server runs; if it does, ask the user to
  look at the session on the other computer and start its wait again there.
- When this computer's address changes, the other side finds it again by itself, by trying its old address's
  neighbours. If it can't (a different network), it tells its user; `zerg tunnel status <role>` shows this
  computer's address now, for the user to pass on. A fixed address for this computer in the router's settings (a
  DHCP reservation) avoids all of it.
- When the session on the other computer was closed, ask the user to paste the prompt into a new one there:
  `zerg tunnel open <role>` alone writes it again, to its prompt.md and the clipboard (with `--host <ip>` after an
  address change).
- The role's mail is for the other computer: never open a session for it here (`zerg task open` refuses), and
  read it only with `zerg mail peek`.

## Closing it

When the work is done, tell the other side by mail that it is finished, stop the server's background job, then
run `zerg tunnel close <role>`. It deletes the key, the secret and the staged files, and prints the folder on the
other computer the user can delete. The role's mail, its state file and the files it sent stay.
