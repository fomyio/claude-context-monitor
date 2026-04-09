#!/usr/bin/env bash
# src/notify.sh — Desktop notification dispatcher
# Usage: notify.sh <level> <title> <message>
# Levels: info | warning | critical | golden

set -euo pipefail

LEVEL="${1:-info}"
TITLE="${2:-Context Monitor}"
MESSAGE="${3:-}"

if [ -z "$MESSAGE" ]; then exit 0; fi

send_macos() {
  local sound=""
  if [ "$LEVEL" = "warning" ] || [ "$LEVEL" = "critical" ]; then
    sound=" sound name \"Basso\""
  fi
  osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"$sound" 2>/dev/null || true
}

send_linux() {
  local urgency="normal"
  if [ "$LEVEL" = "critical" ]; then urgency="critical"; fi
  if [ "$LEVEL" = "warning" ]; then urgency="normal"; fi
  notify-send --urgency="$urgency" "$TITLE" "$MESSAGE" 2>/dev/null || true
}

OS="$(uname -s)"
case "$OS" in
  Darwin) send_macos ;;
  Linux)  send_linux ;;
  *)      true ;;  # unsupported OS, silently skip
esac

exit 0
