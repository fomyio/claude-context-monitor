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

# node is a hard dependency for every step below — bail out cleanly if absent
# so the hook never aborts mid-write under `set -e`.
command -v node >/dev/null 2>&1 || exit 0

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
STATE_DIR="${STATE_DIR_CFG/#\~/$HOME}"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

# Create state file if it doesn't exist (e.g. session-init didn't run).
# Session id passed via env, written atomically — consistent with the main write.
if [ ! -f "$STATE_FILE" ]; then
  mkdir -p "$STATE_DIR"
  SESSION_ID="$SESSION_ID" STATE_FILE="$STATE_FILE" node -e '
    const fs=require("fs");
    const stateFile=process.env.STATE_FILE;
    const tmp=stateFile + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify({
      session_id:process.env.SESSION_ID, token_history:[], topics:[],
      last_compact_at_turn:0, total_turns:0, last_assistant_message:"",
      compact_events:[], last_compact_summary:"", last_compact_timestamp:null,
      last_compact_turn:null, active_task:null
    }, null, 2));
    fs.renameSync(tmp, stateFile);
  ' 2>/dev/null || true
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

# All shell→JS values are passed through the environment and read with
# process.env inside node. We never interpolate them into the JS source, so
# content containing backticks, ${...}, quotes, etc. is treated as plain data
# (no syntax errors, no code execution) — see the injection that the old
# `const stats = $STATS` / `\`$LAST_MSG\`` interpolation allowed.
STATS="$STATS" \
LAST_MSG="$LAST_MSG" \
STATE_FILE="$STATE_FILE" \
SESSION_ID="$SESSION_ID" \
TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
TIMESTAMP="$TIMESTAMP" \
node -e '
  const fs = require("fs");
  const stateFile = process.env.STATE_FILE;
  let stats = {};
  try { stats = JSON.parse(process.env.STATS || "{}"); } catch (_) {}

  // Read the state fresh immediately before mutating, then touch ONLY the fields
  // this writer owns. Everything else is left exactly as read from disk so we
  // never clobber a concurrent writer: statusline owns context_limit/used_*/
  // model/model_display; advisor owns topics/active_task; post-compact owns
  // compact_events/last_compact_*.
  let state;
  try {
    state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch (_) {
    state = { session_id: process.env.SESSION_ID, token_history: [], topics: [], last_compact_at_turn: 0, total_turns: 0, compact_events: [] };
  }

  // Append to token history (owned by this writer)
  state.token_history = state.token_history || [];
  state.token_history.push({
    timestamp: process.env.TIMESTAMP,
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
  state.transcript_path = process.env.TRANSCRIPT_PATH;
  state.last_assistant_message = (process.env.LAST_MSG || "").slice(0, 500);
  state.last_updated = process.env.TIMESTAMP;
  // statusline is authoritative for the live model; only fill in from the
  // transcript-derived model when statusline has not set one yet.
  if (!state.model) state.model = stats.model || "";

  // Atomic write: write to a temp file then rename (atomic on the same fs) so a
  // concurrent reader never observes a torn/partial JSON file.
  const tmp = stateFile + ".tmp." + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, stateFile);
' 2>/dev/null || true

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
