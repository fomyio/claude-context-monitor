#!/usr/bin/env bash
# hooks/post-compact.sh — PostCompact hook
# Reads PostCompact JSON from stdin, resets token history, logs compact event,
# and sends a desktop notification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"
NOTIFY="$PLUGIN_DIR/src/notify.sh"

INPUT="$(cat)"

SESSION_ID="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.session_id ?? d.sessionId ?? '');
" 2>/dev/null || echo '')"

COMPACT_SUMMARY="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  const s=d.compact_summary ?? d.summary ?? '';
  console.log(typeof s === 'string' ? s.substring(0,200) : '');
" 2>/dev/null || echo '')"

TRIGGER="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.trigger ?? 'manual');
" 2>/dev/null || echo 'manual')"

if [ -z "$SESSION_ID" ]; then exit 0; fi

# ── Resolve state file ────────────────────────────────────────────────────────
STATE_DIR_CFG="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.state_dir ?? '~/.claude/plugins/context-monitor/state');
" 2>/dev/null || echo "~/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

if [ ! -f "$STATE_FILE" ]; then exit 0; fi

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── Update state: log compact event, reset token history ─────────────────────
node -e "
  const fs = require('fs');
  let state;
  try {
    state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
  } catch(_) { process.exit(0); }

  const history = state.token_history || [];
  const preTokens = history.length > 0 ? history[history.length - 1].tokens_used : 0;

  // Log compact event
  state.compact_events = state.compact_events || [];
  state.compact_events.push({
    compacted_at: '$TIMESTAMP',
    trigger: '$TRIGGER',
    pre_tokens: preTokens,
    turns_at_compact: state.total_turns,
    summary_preview: \`$COMPACT_SUMMARY\`.substring(0, 100),
  });

  // Reset token history — context was freed
  state.token_history = [];
  state.last_compact_at_turn = state.total_turns;

  fs.writeFileSync('$STATE_FILE', JSON.stringify(state, null, 2));
" 2>/dev/null || true

# ── Send desktop notification ─────────────────────────────────────────────────
bash "$NOTIFY" "info" "🧹 Compact Complete" "Context freed! Session continues fresh. (trigger: $TRIGGER)" 2>/dev/null || true

exit 0
