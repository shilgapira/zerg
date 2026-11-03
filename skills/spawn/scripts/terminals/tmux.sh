open_tab() {
  local window pane
  # new-window -t takes a window, not a pane id
  window="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}')" || return 1
  pane="$(tmux new-window -a -d -t "$window" -n "$name" -c "$dir" -P -F '#{pane_id}')" || return 1
  tmux send-keys -t "$pane" -l "$tab_command" && tmux send-keys -t "$pane" Enter
}
