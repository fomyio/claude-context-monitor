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
STATE_DIR="${STATE_DIR_CFG/#\~/$HOME}"

# Read session JSON from stdin and pipe safely to node (no shell expansion)
# Pass STATE_DIR via env var to avoid embedding it in a JS string literal
cat | STATE_DIR="$STATE_DIR" node -e "
  const fs = require('fs');
  const input = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'));

  // Current model — Claude Code reports it as { id, display_name }, but tolerate
  // a bare string. This is the authoritative live model and follows mid-session
  // model switches, so we both display it and persist it as ground truth.
  // Parsed before the limit so a '[1m]' (1M-context) suffix can override it.
  const modelRaw = input.model ?? '';
  const modelId = (typeof modelRaw === 'object' ? modelRaw.id : modelRaw) || '';
  const modelDisplay = (typeof modelRaw === 'object' ? (modelRaw.display_name || modelRaw.id) : modelRaw) || '';

  // The 1M-context variants advertise themselves with a '[1m]' suffix on the
  // model id (e.g. 'claude-opus-4-8[1m]'). Claude Code's payload doesn't always
  // carry the widened limit_tokens, so floor it at 1,000,000 when we see it —
  // otherwise the bar pins to the 200K default and reports a wrong percentage.
  const is1M = /\[1m\]/i.test(modelId) || /1m\b/i.test(modelDisplay);
  const reportedLimit = input.context_window?.limit_tokens ?? 0;
  const limit = is1M ? Math.max(1000000, reportedLimit) : (reportedLimit || 200000);
  // Either used_tokens or used_percentage may be absent — derive the token count
  // from whichever is present (a missing used_tokens is recovered from the
  // percentage against the limit Claude Code itself used: reportedLimit). The
  // percentage is then always recomputed from used/limit so it stays consistent
  // with the (possibly widened) 1M limit — a stale 200K-based pct can't survive.
  const usedTokRaw = input.context_window?.used_tokens;
  const pctRaw = input.context_window?.used_percentage;
  const used = usedTokRaw ?? (pctRaw != null ? Math.round(pctRaw * (reportedLimit || 200000) / 100) : 0);
  const pct = limit > 0 ? (used / limit) * 100 : 0;
  // cost may live at session.cost, session.cost_usd, or cost.total_cost_usd
  const cost = input.session?.cost ?? input.session?.cost_usd ?? input.cost?.total_cost_usd ?? 0;
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
  if (modelDisplay) parts.push(modelDisplay);

  console.log(parts.join(' · '));

  // Persist the real context data from Claude Code into state so check.sh / analyze.js can use it
  if (sessionId && limit > 0) {
    try {
      const stateFile = stateDir + '/' + sessionId + '.json';
      let state = {};
      try { state = JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch(_) {}
      let changed = false;
      if (state.context_limit !== limit) { state.context_limit = limit; changed = true; }
      if (state.used_tokens !== used) { state.used_tokens = used; changed = true; }
      if (state.used_percentage !== pct) { state.used_percentage = pct; changed = true; }
      if (modelId && state.model !== modelId) { state.model = modelId; changed = true; }
      if (modelDisplay && state.model_display !== modelDisplay) { state.model_display = modelDisplay; changed = true; }
      if (changed) {
        fs.mkdirSync(stateDir, { recursive: true });
        const tmp = stateFile + '.tmp.' + process.pid;
        fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
        fs.renameSync(tmp, stateFile);
      }
    } catch(_) {}
  }
" 2>/dev/null || echo "CTX ?%"
