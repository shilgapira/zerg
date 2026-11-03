# TODO004 Tunnel limits

- **Priority**: Low
- **Status**: Ready
- **Risk**: a compromised remote can fill the boss's disk or inboxes; a few hosts on the LAN can keep the real client
  out.

Found by a review of `scripts/tunnel.py` before the repo went public:
- An authenticated remote has no quota: each upload may be 2 GB, with no limit on how many, and mail is unlimited.
- An attacker with a few LAN addresses can hold all 16 connection slots by sitting in the TLS handshake; the real
  client retries for a minute and gives up.
- `--host` isn't validated: a quote breaks the generated client script, and an IPv6 address breaks its URL while
  the server listens on IPv4 only.

## Options

1. Cap the size of `received/` and the unread mail per inbox (refusing past it); hold a few slots back for
   requests that showed the secret, or shorten the pre-auth deadline; check `--host` with `ipaddress.IPv4Address`.
2. Leave them: each needs someone hostile on the network or a compromised remote.

## Recommendation

Option 1 for `--host` (one line); the rest when the tunnel is used on shared networks.
