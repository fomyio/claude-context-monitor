#!/usr/bin/env node
/**
 * dashboard.js — CLI Report
 *
 * Usage:
 *   node src/dashboard.js
 *   context-monitor report
 *
 * Displays a CLI dashboard summarizing the current session's usage,
 * cost, burn rate, and a recommendation.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { analyzeTranscript } = require('./analyze');

const configPath = path.join(__dirname, '..', 'config.json');
let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch(_) {}

const stateDirCfg = config.state_dir || '~/.claude/plugins/context-monitor/state';
const stateDir = stateDirCfg.replace(/^~/, process.env.HOME);

// Find the most recent session state
let latestSession = null;
let latestTime = 0;

if (fs.existsSync(stateDir)) {
  const files = fs.readdirSync(stateDir).filter(f => f.endsWith('.json'));
  for (const f of files) {
    const stat = fs.statSync(path.join(stateDir, f));
    if (stat.mtimeMs > latestTime) {
      latestTime = stat.mtimeMs;
      latestSession = path.join(stateDir, f);
    }
  }
}

if (!latestSession) {
  console.log('No context-monitor session found.');
  process.exit(0);
}

let state;
try {
  state = JSON.parse(fs.readFileSync(latestSession, 'utf8'));
} catch (err) {
  console.error('Failed to read session state:', err.message);
  process.exit(1);
}

const {
  session_id,
  model,
  started_at,
  transcript_path,
  total_turns,
  topics = [],
  claude_md_tokens = 0,
  token_history = []
} = state;

// Get latest stats — try live transcript first, fall back to last recorded state
let stats = {};
if (transcript_path) {
  stats = analyzeTranscript(transcript_path, model) || {};
}
// If no transcript or analysis returned nothing, use the latest token_history entry
if (!stats.tokens_used && token_history.length > 0) {
  const last = token_history[token_history.length - 1];
  stats = {
    tokens_used: last.tokens_used || 0,
    tokens_max: 200000,
    usage_pct: last.usage_pct || 0,
    burn_rate: last.burn_rate || 0,
    turns_left: last.burn_rate > 0 ? Math.floor((200000 - (last.tokens_used || 0)) / last.burn_rate) : null,
    estimated_cost_usd: 0,
    cache_efficiency: 0,
  };
}
const usedK = Math.round((stats.tokens_used || 0) / 1000);
const maxK = Math.round((stats.tokens_max || 200000) / 1000);
const usagePct = stats.usage_pct || 0;
const cost = stats.estimated_cost_usd || 0;
const eff = stats.cache_efficiency || 0;
const burnRate = stats.burn_rate || 0;
const turnsLeft = stats.turns_left !== null ? stats.turns_left : '?';

const uptimeMs = started_at ? Date.now() - new Date(started_at).getTime() : 0;
const uptimeMin = uptimeMs > 0 ? Math.round(uptimeMs / 60000) : '?';

// Draw bar
const BAR_WIDTH = 40;
const filled = Math.round(BAR_WIDTH * usagePct / 100);
const empty = Math.max(0, BAR_WIDTH - filled);
const bar = '█'.repeat(filled) + '░'.repeat(empty);

// Topics format
let topicsStr = topics.map(t => t.label).join(' → ');
if (!topicsStr) topicsStr = 'General';

console.log(`
Session: ${total_turns} turns | ${uptimeMin} min | ${model || 'unknown'}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Context:  [${bar}]  ${usagePct}%  (${usedK}K / ${maxK}K)
Cost:     ~$${cost.toFixed(3)} this session  |  Cache eff: ${Math.round(eff * 100)}%
Burn:     ~${burnRate} tokens/turn   |  ~${turnsLeft} turns remaining
Topics:   [${topicsStr}]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);

// Recommendation mock (since we evaluate live in check.sh hook)
if (usagePct >= 85) {
  console.log('Recommendation: 🚨 URGENT — Context limit critical. Run /compact NOW.');
} else if (usagePct >= 70) {
  console.log('Recommendation: ⚠️ Warning — Context threshold high. Consider /compact.');
} else if (claude_md_tokens > 20000) {
  console.log(`Recommendation: ⚠️ CLAUDE.md tracking bloat (~${claude_md_tokens} tokens). Clean it up.`);
} else {
  console.log('Recommendation: 🟢 Healthy context. No action needed.');
}
