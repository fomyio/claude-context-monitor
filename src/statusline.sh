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
  // carry the widened window size, so floor it at 1,000,000 when we see it —
  // otherwise the bar pins to the 200K default and reports a wrong percentage.
  // Keyed on the id only: it's the canonical signal, and a looser display-name
  // match (e.g. /1m\b/) would false-positive on names that merely end in "1m".
  const is1M = /\[1m\]/i.test(modelId);
  // Claude Code (≥2.x) names these fields context_window_size and
  // total_input_tokens; limit_tokens / used_tokens are legacy spellings kept
  // as fallbacks. Reading only the legacy names left the token count undefined
  // and forced the lossy percentage fallback below.
  // total_input_tokens is the latest call's input + cache_creation + cache_read
  // (Claude Code pre-sums them) — i.e. current context occupancy. Output tokens
  // are deliberately excluded to match Claude Code's own used_percentage;
  // adding them can push the bar past 100% right after a long response.
  const cw = input.context_window ?? {};
  const reportedLimit = cw.context_window_size ?? cw.limit_tokens ?? 0;
  const limit = is1M ? Math.max(1000000, reportedLimit) : (reportedLimit || 200000);
  const usedTokRaw = cw.total_input_tokens != null ? cw.total_input_tokens : cw.used_tokens;
  // Last-resort fallback: recover tokens from used_percentage against the limit
  // in effect ('limit', not the 200K default — Claude Code computes the pct
  // against the real window, so scaling a 1M session by 200K understates usage
  // 5×). used_percentage is also integer-rounded, hence tokens are preferred.
  // The pct is always recomputed from used/limit so it stays consistent with
  // the (possibly widened) 1M limit — a stale 200K-based pct can't survive.
  const pctRaw = cw.used_percentage;
  const used = usedTokRaw ?? (pctRaw != null ? Math.round(pctRaw * limit / 100) : 0);
  const pct = limit > 0 ? Math.min(100, (used / limit) * 100) : 0;
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
          turnsLeft = String(Math.floor(Math.max(0, limit - used) / burnRate));
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
      // Before the first API response of a (resumed) session the payload carries
      // zeroed token fields and a null percentage — don't clobber the previous
      // run's accurate numbers with 0s.
      const hasUsage = used > 0 || pctRaw != null;
      if (hasUsage && state.used_tokens !== used) { state.used_tokens = used; changed = true; }
      if (hasUsage && state.used_percentage !== pct) { state.used_percentage = pct; changed = true; }
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
