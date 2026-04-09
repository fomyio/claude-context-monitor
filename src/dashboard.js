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
  claude_md_tokens = 0
} = state;

// Get latest stats
const stats = analyzeTranscript(transcript_path, model) || {};
const usedK = Math.round((stats.tokens_used || 0) / 1000);
const maxK = Math.round((stats.tokens_max || 200000) / 1000);
const usagePct = stats.usage_pct || 0;
const cost = stats.estimated_cost_usd || 0;
const eff = stats.cache_efficiency || 0;
const burnRate = stats.burn_rate || 0;
const turnsLeft = stats.turns_left !== null ? stats.turns_left : '?';

const uptimeMs = Date.now() - new Date(started_at).getTime();
const uptimeMin = Math.round(uptimeMs / 60000);

// Draw bar
const BAR_WIDTH = 40;
const filled = Math.round(BAR_WIDTH * usagePct / 100);
const empty = Math.max(0, BAR_WIDTH - filled);
const bar = '█'.repeat(filled) + '░'.repeat(empty);

// Topics format
let topicsStr = topics.map(t => t.label).join(' → ');
if (!topicsStr) topicsStr = 'General';

console.log(`
Session: ${total_turns} turns | ${uptimeMin} min | ${model}
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
