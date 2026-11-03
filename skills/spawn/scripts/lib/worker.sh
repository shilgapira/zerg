normalize_autocompact() {
  local ac tokens
  ac="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [ "$ac" = auto ]; then
    echo auto
    return 0
  fi
  # at most 7 digits, so the arithmetic below cannot overflow and wrap into the valid range
  [[ "$ac" =~ ^([0-9]{1,7})([km]?)$ ]] || return 1
  tokens=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    k) tokens=$((tokens * 1000)) ;;
    m) tokens=$((tokens * 1000000)) ;;
    *) [ "$tokens" -ge 1000 ] || tokens=$((tokens * 1000)) ;;
  esac
  [ "$tokens" -ge 100000 ] && [ "$tokens" -le 1000000 ] || return 1
  echo "$tokens"
}

report_protocol() {
  # printf repeats %s for each argument, so the pieces join with nothing between them
  printf '%s' \
    "You are a worker session started by the Claude Code session named \"$1\". " \
    "When you start, before anything else, SendMessage to \"$1\" saying you are running. " \
    "Whenever you finish the task or get blocked, report to \"$1\" the same way. " \
    "If your conversation was compacted (it continues from a summary of earlier work), do not send the start " \
    "message again; instead SendMessage to \"$1\" a short status: that you were compacted, where the task stands, " \
    "and what you are doing next."
}
