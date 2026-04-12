#!/usr/bin/env bash
# hooks/update-state.sh — Stop hook (async)
# Reads Stop hook JSON from stdin, calls analyze.js, persists stats to state file.
# Registered as a background hook — does NOT block the user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"
ANALYZE="$PLUGIN_DIR/src/analyze.js"
NOTIFY="$PLUGIN_DIR/src/notify.sh"

INPUT="$(cat)"

SESSION_ID="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.session_id ?? d.sessionId ?? '');
" 2>/dev/null || echo '')"

TRANSCRIPT_PATH="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.transcript_path ?? d.transcriptPath ?? '');
" 2>/dev/null || echo '')"

LAST_MSG="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  // Try various fields for the last assistant message content
  const msg = d.message ?? d.assistant_message ?? '';
  if (typeof msg === 'string') { console.log(msg.substring(0, 500)); }
  else if (Array.isArray(msg?.content)) {
    const text = msg.content.filter(b=>b.type==='text').map(b=>b.text).join(' ');
    console.log(text.substring(0, 500));
  } else { console.log(''); }
" 2>/dev/null || echo '')"

if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT_PATH" ]; then exit 0; fi

# ── Resolve state dir ─────────────────────────────────────────────────────────
STATE_DIR_CFG="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.state_dir ?? '~/.claude/plugins/context-monitor/state');
" 2>/dev/null || echo "~/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

# Create state file if it doesn't exist (e.g. session-init didn't run)
if [ ! -f "$STATE_FILE" ]; then
  mkdir -p "$STATE_DIR"
  node -e "
    const fs=require('fs');
    fs.writeFileSync('$STATE_FILE', JSON.stringify({
      session_id:'$SESSION_ID', token_history:[], topics:[],
      last_compact_at_turn:0, total_turns:0, last_assistant_message:'',
      compact_events:[], last_compact_summary:'', last_compact_timestamp:null,
      last_compact_turn:null, active_task:null
    }, null, 2));
  " 2>/dev/null || true
fi

# ── Get token stats ───────────────────────────────────────────────────────────
MODEL="$(node -e "
  try {
    const s=JSON.parse(require('fs').readFileSync('$STATE_FILE','utf8'));
    console.log(s.model ?? '');
  } catch(_) { console.log(''); }
" 2>/dev/null || echo '')"

STATS="$(node "$ANALYZE" "$TRANSCRIPT_PATH" "$MODEL" "$SESSION_ID" 2>/dev/null || echo '{}')"

if [ "$STATS" = '{}' ] || [ -z "$STATS" ]; then exit 0; fi

# ── Persist stats to state ────────────────────────────────────────────────────
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Sanitise paths that get embedded in JS string literals (strip single quotes)
SAFE_TRANSCRIPT="${TRANSCRIPT_PATH//\'/}"
SAFE_STATE_FILE="${STATE_FILE//\'/}"
SAFE_SESSION_ID="${SESSION_ID//\'/}"

node -e "
  const fs = require('fs');
  const stats = $STATS;
  let state;
  try {
    state = JSON.parse(fs.readFileSync('$SAFE_STATE_FILE', 'utf8'));
  } catch(_) {
    state = { session_id: '$SAFE_SESSION_ID', token_history: [], topics: [], last_compact_at_turn: 0, total_turns: 0, compact_events: [] };
  }

  // Append to token history
  state.token_history = state.token_history || [];
  state.token_history.push({
    timestamp: '$TIMESTAMP',
    tokens_used: stats.tokens_used,
    tokens_input: stats.tokens_input,
    usage_pct: stats.usage_pct,
    burn_rate: stats.burn_rate,
    cache_efficiency: stats.cache_efficiency ?? 0,
  });

  // Keep history capped at 50 entries
  if (state.token_history.length > 50) {
    state.token_history = state.token_history.slice(-50);
  }

  state.total_turns = stats.total_turns;
  state.transcript_path = '$SAFE_TRANSCRIPT';
  state.model = stats.model || state.model || '';
  state.last_assistant_message = \`$LAST_MSG\`.substring(0, 500);
  state.last_updated = '$TIMESTAMP';

  // Preserve context_limit written by statusline.sh — re-read before write to
  // avoid clobbering it in the concurrent read-modify-write race
  try {
    const fresh = JSON.parse(fs.readFileSync('$SAFE_STATE_FILE', 'utf8'));
    if (fresh.context_limit) state.context_limit = fresh.context_limit;
  } catch(_) {}

  fs.writeFileSync('$SAFE_STATE_FILE', JSON.stringify(state, null, 2));
" 2>/dev/null || true

# ── Tmux status bar integration (opt-in) ─────────────────────────────────────
TMUX_ENABLED="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.tmux_status_enabled ? 'true' : 'false');
" 2>/dev/null || echo 'false')"

if [ "$TMUX_ENABLED" = "true" ]; then
  TMUX_FILE="$(node -e "
    const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
    console.log(c.tmux_status_file ?? '/tmp/claude-ctx-status');
  " 2>/dev/null || echo '/tmp/claude-ctx-status')"

  USAGE_PCT="$(echo "$STATS" | node -e "
    const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log(d.usage_pct ?? 0);
  " 2>/dev/null || echo 0)"

  TURNS_LEFT="$(echo "$STATS" | node -e "
    const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log(d.turns_left != null ? d.turns_left + ' turns' : '?');
  " 2>/dev/null || echo '?')"

  COST="$(echo "$STATS" | node -e "
    const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    console.log('\$' + (d.estimated_cost_usd ?? 0).toFixed(3));
  " 2>/dev/null || echo '$?')"

  echo "CTX ${USAGE_PCT}% | ~${TURNS_LEFT} | ${COST}" > "$TMUX_FILE" 2>/dev/null || true
fi

exit 0
