#!/usr/bin/env bash
# hooks/check.sh — UserPromptSubmit orchestrator
# Reads hook JSON from stdin, analyzes token usage, renders token bar,
# and invokes advisor.js above the relevance eval threshold.
#
# Exit codes:
#   0 — allow prompt (may inject status text into stdout for Claude's context)
#   2 — block prompt (compact_score > block threshold)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"
ANALYZE="$PLUGIN_DIR/src/analyze.js"
ADVISOR="$PLUGIN_DIR/src/advisor.js"
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

NEW_PROMPT="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  // prompt may be in d.prompt or d.message
  const p = d.prompt ?? (typeof d.message === 'string' ? d.message : '') ?? '';
  console.log(p.substring(0, 500));
" 2>/dev/null || echo '')"

if [ -z "$TRANSCRIPT_PATH" ]; then exit 0; fi

# ── Resolve state ─────────────────────────────────────────────────────────────
STATE_DIR_CFG="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.state_dir ?? '~/.claude/plugins/context-monitor/state');
" 2>/dev/null || echo "~/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"
STATE_FILE="$STATE_DIR/${SESSION_ID}.json"

MODEL="$(node -e "
  try {
    const s=JSON.parse(require('fs').readFileSync('$STATE_FILE','utf8'));
    console.log(s.model ?? '');
  } catch(_) { console.log(''); }
" 2>/dev/null || echo '')"

# ── Analyze token usage ───────────────────────────────────────────────────────
STATS="$(node "$ANALYZE" "$TRANSCRIPT_PATH" "$MODEL" "$SESSION_ID" 2>/dev/null || echo '{}')"

if [ "$STATS" = '{}' ] || [ -z "$STATS" ]; then
  exit 0
fi

USAGE_PCT="$(echo "$STATS" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.usage_pct ?? 0);
" 2>/dev/null || echo 0)"

TOKENS_USED="$(echo "$STATS" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.tokens_used ?? 0);
" 2>/dev/null || echo 0)"

TOKENS_MAX="$(echo "$STATS" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.tokens_max ?? 200000);
" 2>/dev/null || echo 200000)"

TURNS_LEFT="$(echo "$STATS" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.turns_left != null ? d.turns_left : '?');
" 2>/dev/null || echo '?')"

BURN_RATE="$(echo "$STATS" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.burn_rate ?? 0);
" 2>/dev/null || echo 0)"

# ── Render token bar ──────────────────────────────────────────────────────────
render_bar() {
  local pct="$1"
  local turns="$2"
  local used="$3"
  local max="$4"

  node -e "
    const pct = parseFloat('$pct') || 0;
    const BAR_WIDTH = 20;
    const filled = Math.round(BAR_WIDTH * pct / 100);
    const empty = Math.max(0, BAR_WIDTH - filled);

    let color = '';
    if (pct >= 85) color = '🔴';
    else if (pct >= 70) color = '🟡';
    else color = '🟢';

    const bar = '█'.repeat(filled) + '░'.repeat(empty);
    const turnsText = '$turns' !== '?' ? '~$turns turns left' : 'burn rate calculating';
    const usedK = Math.round($used / 1000);
    const maxK = Math.round($max / 1000);

    console.log(\`[CTX] \${color} [\${bar}] \${pct.toFixed(1)}% | \${usedK}K/\${maxK}K | \${turnsText}\`);
  " 2>/dev/null || echo "[CTX] [??????????????????] ${pct}% | tokens: ${TOKENS_USED}/${TOKENS_MAX}"
}

TOKEN_BAR="$(render_bar "$USAGE_PCT" "$TURNS_LEFT" "$TOKENS_USED" "$TOKENS_MAX")"

# ── Notify on usage thresholds ────────────────────────────────────────────────
INFO_PCT="$(node -e "const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8')); console.log(c.notify_thresholds?.info ?? 70);" 2>/dev/null || echo 70)"
WARN_PCT="$(node -e "const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8')); console.log(c.notify_thresholds?.warning ?? 85);" 2>/dev/null || echo 85)"
CRIT_PCT="$(node -e "const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8')); console.log(c.notify_thresholds?.critical ?? 95);" 2>/dev/null || echo 95)"
BLOCK_PCT="$(node -e "const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8')); console.log(c.compact_score_thresholds?.block ?? 80);" 2>/dev/null || echo 80)"

# Only notify once per threshold crossing (track in state)
check_and_notify_threshold() {
  local pct="$1"
  local threshold="$2"
  local level="$3"
  local title="$4"
  local msg="$5"
  local flag_key="notified_${threshold}"

  if node -e "
    const pct = parseFloat('$pct');
    const threshold = parseFloat('$threshold');
    if (pct < threshold) process.exit(1);
    try {
      const fs=require('fs');
      const state=JSON.parse(fs.readFileSync('$STATE_FILE','utf8'));
      if (state['$flag_key']) process.exit(1); // already notified
    } catch(_) {}
    process.exit(0);
  " 2>/dev/null; then
    bash "$NOTIFY" "$level" "$title" "$msg" &
    # Mark as notified in state
    node -e "
      const fs=require('fs');
      try {
        const state=JSON.parse(fs.readFileSync('$STATE_FILE','utf8'));
        state['$flag_key']=true;
        fs.writeFileSync('$STATE_FILE',JSON.stringify(state,null,2));
      } catch(_){}
    " 2>/dev/null || true
  fi
}

check_and_notify_threshold "$USAGE_PCT" "$INFO_PCT" "info" "🧠 Context Monitor" "Context at ${USAGE_PCT}%. ~${TURNS_LEFT} turns remaining."
check_and_notify_threshold "$USAGE_PCT" "$WARN_PCT" "warning" "⚠️ Context Warning" "Context at ${USAGE_PCT}%! Consider compacting soon."
check_and_notify_threshold "$USAGE_PCT" "$CRIT_PCT" "critical" "🚨 Context Critical" "Context at ${USAGE_PCT}%! Compact NOW before you hit the limit."

# ── Simple mode (≤ 45%): just print the bar ──────────────────────────────────
EVAL_THRESHOLD="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.relevance_eval_threshold_pct ?? 45);
" 2>/dev/null || echo 45)"

EVAL_ENABLED="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.relevance_eval_enabled !== false ? 'true' : 'false');
" 2>/dev/null || echo 'true')"

# Check if below advisor threshold
BELOW_THRESHOLD="$(node -e "
  const pct=parseFloat('$USAGE_PCT');
  const threshold=parseFloat('$EVAL_THRESHOLD');
  console.log(pct <= threshold ? 'true' : 'false');
" 2>/dev/null || echo 'true')"

if [ "$BELOW_THRESHOLD" = "true" ] || [ "$EVAL_ENABLED" = "false" ]; then
  echo "$TOKEN_BAR"
  exit 0
fi

# ── Intelligence mode (> 45%): invoke advisor.js ──────────────────────────────
if [ ! -f "$ADVISOR" ]; then
  # advisor not yet implemented — fall back to token bar only
  echo "$TOKEN_BAR"
  exit 0
fi

ADVISOR_RESULT="$(node "$ADVISOR" \
  --transcript "$TRANSCRIPT_PATH" \
  --session "$SESSION_ID" \
  --prompt "$NEW_PROMPT" \
  --stats "$STATS" \
  --state-file "$STATE_FILE" \
  --config "$CONFIG" \
  2>/dev/null || echo '{"compact_score":0,"action":"allow","output":""}')"

ACTION="$(echo "$ADVISOR_RESULT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.action ?? 'allow');
" 2>/dev/null || echo 'allow')"

ADVISOR_OUTPUT="$(echo "$ADVISOR_RESULT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.output ?? '');
" 2>/dev/null || echo '')"

COMPACT_SCORE="$(echo "$ADVISOR_RESULT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.compact_score ?? 0);
" 2>/dev/null || echo 0)"

# Print token bar + advisor output to stdout (injected into Claude's context)
echo "$TOKEN_BAR"
if [ -n "$ADVISOR_OUTPUT" ]; then
  echo "$ADVISOR_OUTPUT"
fi

# Block if score is critical and block_on_critical is enabled or action=block
BLOCK_ENABLED="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.block_on_critical !== false ? 'true' : 'false');
" 2>/dev/null || echo 'false')"

if [ "$ACTION" = "block" ] && [ "$BLOCK_ENABLED" = "true" ]; then
  bash "$NOTIFY" "critical" "🚨 Context Blocked" "Compact score ${COMPACT_SCORE}. Please run /compact before continuing." &
  exit 2
fi

exit 0
