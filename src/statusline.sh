#!/bin/bash
# src/statusline.sh — Claude Code status line script
# Receives JSON session data on stdin, outputs a context status bar.
# Augments built-in data with plugin state (burn rate, turns left).

set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR_CFG="$(node -e "
  try {
    const c=JSON.parse(require('fs').readFileSync('$PLUGIN_DIR/config.json','utf8'));
    console.log(c.state_dir ?? '~/.claude/context-monitor-state');
  } catch(_) { console.log('~/.claude/context-monitor-state'); }
" 2>/dev/null || echo '~/.claude/context-monitor-state')"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"

# Read session JSON from stdin
INPUT="$(cat)"

# Extract built-in fields from Claude Code
node -e "
  const input = $INPUT;
  const fs = require('fs');

  const pct = input.context_window?.used_percentage ?? 0;
  const used = input.context_window?.used_tokens ?? 0;
  const limit = input.context_window?.limit_tokens ?? 200000;
  const cost = input.session?.cost ?? 0;
  const sessionId = input.session_id ?? '';

  // Try to read plugin state for burn rate / turns left
  let burnRate = 0;
  let turnsLeft = '?';
  const stateDir = '$STATE_DIR';

  if (sessionId) {
    try {
      const state = JSON.parse(fs.readFileSync(stateDir + '/' + sessionId + '.json', 'utf8'));
      const history = state.token_history || [];
      if (history.length > 0) {
        const last = history[history.length - 1];
        burnRate = last.burn_rate || 0;
        if (burnRate > 0) {
          turnsLeft = String(Math.floor((limit - used) / burnRate));
        }
      }
    } catch(_) {}
  }

  // Pick color indicator
  let icon = '\u2713';  // checkmark
  if (pct >= 85) icon = '\u26a0';      // warning
  else if (pct >= 70) icon = '\u25cf';  // dot

  const usedK = Math.round(used / 1000);
  const limitK = Math.round(limit / 1000);
  const costStr = cost > 0 ? cost.toFixed(3) : '0.00';

  const parts = [
    'CTX ' + pct.toFixed(0) + '%',
    usedK + 'K/' + limitK + 'K',
  ];

  if (turnsLeft !== '?') parts.push('~' + turnsLeft + ' turns');
  parts.push('\$' + costStr);

  console.log(icon + ' ' + parts.join(' | '));
" 2>/dev/null || echo "CTX ?%"
