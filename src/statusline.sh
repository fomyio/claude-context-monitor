#!/bin/bash
# src/statusline.sh — Claude Code status line script
# Receives JSON session data on stdin, outputs a context status bar.
# Augments built-in data with plugin state (burn rate, turns left).

set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR_CFG="$(node -e "
  try {
    const c=JSON.parse(require('fs').readFileSync('$PLUGIN_DIR/config.json','utf8'));
    console.log(c.state_dir ?? '~/.claude/plugins/context-monitor/state');
  } catch(_) { console.log('~/.claude/plugins/context-monitor/state'); }
" 2>/dev/null || echo '~/.claude/plugins/context-monitor/state')"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"

# Read session JSON from stdin and pipe safely to node (no shell expansion)
# Pass STATE_DIR via env var to avoid embedding it in a JS string literal
cat | STATE_DIR="$STATE_DIR" node -e "
  const fs = require('fs');
  const input = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'));

  const pct = input.context_window?.used_percentage ?? 0;
  const limit = input.context_window?.limit_tokens ?? 200000;
  // used_tokens may be absent — derive from percentage when missing
  const used = input.context_window?.used_tokens ?? Math.round(pct * limit / 100);
  // cost may live at session.cost or session.cost_usd
  const cost = input.session?.cost ?? input.session?.cost_usd ?? 0;
  const sessionId = input.session_id ?? '';

  // Try to read plugin state for burn rate / turns left / cache efficiency
  let burnRate = 0;
  let turnsLeft = '?';
  let cacheEff = null;
  const stateDir = process.env.STATE_DIR;

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
        if (last.cache_efficiency != null && last.cache_efficiency > 0) {
          cacheEff = Math.round(last.cache_efficiency * 100);
        }
      }
    } catch(_) {}
  }

  // Progress bar — █ filled, ░ empty (matches dashboard style)
  const BAR_WIDTH = 20;
  const filled = Math.min(BAR_WIDTH, Math.round(BAR_WIDTH * pct / 100));
  const empty = Math.max(0, BAR_WIDTH - filled);
  const bar = '[' + '\u2588'.repeat(filled) + '\u2591'.repeat(empty) + ']';

  // Color indicator
  let icon;
  if (pct >= 85) icon = '\uD83D\uDD34';       // 🔴
  else if (pct >= 70) icon = '\uD83D\uDFE1';  // 🟡
  else icon = '\uD83D\uDFE2';                  // 🟢

  const usedK = Math.round(used / 1000);
  const limitK = Math.round(limit / 1000);
  const costStr = '\$' + (cost > 0 ? cost.toFixed(3) : '0.00');

  const parts = [icon + ' ' + bar + ' ' + pct.toFixed(1) + '%'];
  parts.push(usedK + 'K/' + limitK + 'K');
  if (turnsLeft !== '?') parts.push('~' + turnsLeft + ' turns');
  parts.push(costStr);
  if (cacheEff !== null) parts.push('eff ' + cacheEff + '%');

  console.log(parts.join(' · '));

  // Persist the real context limit from Claude Code into state so analyze.js can use it
  if (sessionId && limit > 0) {
    try {
      const stateFile = stateDir + '/' + sessionId + '.json';
      let state = {};
      try { state = JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch(_) {}
      if (state.context_limit !== limit) {
        state.context_limit = limit;
        fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
      }
    } catch(_) {}
  }
" 2>/dev/null || echo "CTX ?%"
