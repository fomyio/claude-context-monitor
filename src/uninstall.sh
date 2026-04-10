#!/usr/bin/env bash
# src/uninstall.sh — Manual cleanup for claude-context-monitor plugin.
# Run this if you've removed the plugin and still see leftover artifacts.
# Usage: bash ~/.claude/plugins/context-monitor/src/uninstall.sh

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
WRAPPER="$HOME/.claude/statusline.sh"

echo "[context-monitor] Cleaning up plugin artifacts..."

# Remove statusLine from settings.json (only if it points to our wrapper),
# then only remove the wrapper if settings.json was actually cleaned up.
# This prevents a stale statusLine entry pointing to a deleted wrapper file.
if [ -f "$SETTINGS_FILE" ]; then
  if node -e "
    const fs = require('fs');
    const s = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
    if (s.statusLine && s.statusLine.command === '~/.claude/statusline.sh') {
      delete s.statusLine;
      fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(s, null, 2));
      console.log('  Removed statusLine from settings.json');
    } else if (s.statusLine) {
      console.log('  statusLine exists but points elsewhere — leaving it untouched');
    } else {
      console.log('  statusLine not found in settings.json (already clean)');
    }
  " 2>/dev/null; then
    if [ -f "$WRAPPER" ]; then
      rm -f "$WRAPPER"
      echo "  Removed $WRAPPER"
    else
      echo "  $WRAPPER not found (already clean)"
    fi
  else
    echo "  Warning: could not update settings.json — leaving $WRAPPER intact to avoid a stale pointer"
  fi
fi

echo "[context-monitor] Done."
