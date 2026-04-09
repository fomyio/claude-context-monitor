#!/usr/bin/env bash
# hooks/session-init.sh — SessionStart hook
# Reads SessionStart JSON from stdin, creates per-session state file
# and checks CLAUDE.md bloat.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"

# ── Helper: read config value ─────────────────────────────────────────────────
config_get() {
  node -e "
    const c = JSON.parse(require('fs').readFileSync('$CONFIG', 'utf8'));
    const keys = '$1'.split('.');
    let v = c;
    for (const k of keys) v = v?.[k];
    console.log(v ?? '$2');
  " 2>/dev/null || echo "$2"
}

# ── Read hook input ───────────────────────────────────────────────────────────
INPUT="$(cat)"
SESSION_ID="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.session_id ?? d.sessionId ?? '');" 2>/dev/null || echo '')"
MODEL="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.model ?? '');" 2>/dev/null || echo '')"
TRANSCRIPT_PATH="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.transcript_path ?? d.transcriptPath ?? '');" 2>/dev/null || echo '')"

if [ -z "$SESSION_ID" ]; then
  # Cannot initialize without session id — exit silently
  exit 0
fi

# ── Resolve state dir ─────────────────────────────────────────────────────────
STATE_DIR_CFG="$(config_get state_dir "$HOME/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"
mkdir -p "$STATE_DIR"

STATE_FILE="$STATE_DIR/$SESSION_ID.json"

# ── Create initial state file ─────────────────────────────────────────────────
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
node -e "
const fs = require('fs');
const state = {
  session_id: '$SESSION_ID',
  model: '$MODEL',
  started_at: '$STARTED_AT',
  transcript_path: '$TRANSCRIPT_PATH',
  token_history: [],
  topics: [],
  last_compact_at_turn: 0,
  total_turns: 0,
  last_assistant_message: '',
  claude_md_tokens: 0,
  compact_events: []
};
fs.writeFileSync('$STATE_FILE', JSON.stringify(state, null, 2));
" 2>/dev/null

# ── CLAUDE.md bloat check ─────────────────────────────────────────────────────
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
# Also check local CLAUDE.md
LOCAL_CLAUDE_MD="$(pwd)/CLAUDE.md"

BLOAT_THRESHOLD="$(config_get claude_md_bloat_threshold_pct 15)"

check_claude_md_bloat() {
  local md_path="$1"
  local label="$2"
  if [ ! -f "$md_path" ]; then return; fi

  local size_bytes
  size_bytes="$(wc -c < "$md_path" | tr -d ' ')"
  local model_limit
  model_limit="$(node -e "
    const c = JSON.parse(require('fs').readFileSync('$CONFIG', 'utf8'));
    const m = '$MODEL' || 'claude-sonnet-4-6';
    const limits = c.context_limits || {};
    let limit = 200000;
    for (const [k,v] of Object.entries(limits)) {
      if (m.startsWith(k) || k.startsWith(m)) { limit = v; break; }
    }
    console.log(limit);
  " 2>/dev/null || echo 200000)"

  # Estimate tokens: chars / 3.5
  local est_tokens
  est_tokens=$(( size_bytes * 10 / 35 ))
  local threshold_tokens
  threshold_tokens=$(( model_limit * BLOAT_THRESHOLD / 100 ))

  if [ "$est_tokens" -gt "$threshold_tokens" ]; then
    echo "[CTX] ⚠️  $label is large (~${est_tokens} tokens = $(( est_tokens * 100 / model_limit ))% of context). Consider trimming it."
  fi

  # Persist to state
  node -e "
    const fs = require('fs');
    const state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
    state.claude_md_tokens = $est_tokens;
    fs.writeFileSync('$STATE_FILE', JSON.stringify(state, null, 2));
  " 2>/dev/null || true
}

check_claude_md_bloat "$CLAUDE_MD" "~/.claude/CLAUDE.md"
check_claude_md_bloat "$LOCAL_CLAUDE_MD" "CLAUDE.md"

exit 0
