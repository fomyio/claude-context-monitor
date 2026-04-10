#!/usr/bin/env bash
# src/uninstall.sh — Manual cleanup for claude-context-monitor plugin.
# Run this if you've removed the plugin and still see leftover artifacts.
# Usage: bash ~/.claude/plugins/context-monitor/src/uninstall.sh

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
WRAPPER="$HOME/.claude/statusline.sh"

echo "[context-monitor] Cleaning up plugin artifacts..."

# Remove orphaned cache directories left by Claude Code's plugin manager
CACHE_DIR="$HOME/.claude/plugins/cache/claude-context-monitor"
if [ -d "$CACHE_DIR" ]; then
  orphaned_count=0
  for dir in "$CACHE_DIR"/*/; do
    for ver in "$dir"*/; do
      if [ -f "$ver/.orphaned_at" ]; then
        rm -rf "$ver"
        orphaned_count=$((orphaned_count + 1))
      fi
    done
  done
  if [ "$orphaned_count" -gt 0 ]; then
    echo "  Removed $orphaned_count orphaned cache directory(ies)"
  else
    echo "  No orphaned cache directories found"
  fi
fi

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
