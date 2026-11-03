# TODO005 A one-time enrollment token for the tunnel

- **Priority**: Medium
- **Status**: Needs decision
- **Risk**: the long-lived secret in the setup prompt stays valid wherever the prompt was kept.

The prompt the user pastes into the other computer's session holds the channel's secret. It ends up in that
agent's transcript and its model provider's logs, and by default on the clipboard (`scripts/tunnel.py`, `open`),
where macOS Universal Clipboard or Windows clipboard history can sync or keep it. Anyone with a copy can use the
channel until it is closed.

## Options

1. A one-time enrollment token in the prompt: the server swaps it for a per-client secret on the first fetch of
   `tunnel.py`, so a leaked prompt is useless afterwards. Copying to the clipboard becomes opt-in.
2. Only make the clipboard copy opt-in.
3. Keep the current design: the prompt is written to a 0600 file and the user moves it by a private route.

## Recommendation

Option 1, as a plan first (`etc/plans/`): it changes the setup handshake on both sides, and the flow test's tunnel
steps would need to cover the swap and a reused token.
