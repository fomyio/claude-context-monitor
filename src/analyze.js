#!/usr/bin/env node
/**
 * analyze.js — Token analyzer: JSONL → usage stats
 *
 * Usage:
 *   node src/analyze.js <transcript_path> <model> <session_id>
 *   node src/analyze.js <transcript_path> <model> <session_id> --json
 *
 * Outputs JSON to stdout.
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ── Model config ─────────────────────────────────────────────────────────────

const CONFIG_PATH = path.join(__dirname, '..', 'config.json');
let config = {};
try {
  config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (_) {}

const CONTEXT_LIMITS = config.context_limits || {
  'claude-sonnet-4-6': 200000,
  'claude-haiku-4-5': 200000,
  'claude-opus-4': 200000,
};

const MODEL_PRICES = config.model_prices_per_million_input || {
  'claude-sonnet-4-6': 3.00,
  'claude-haiku-4-5': 0.80,
  'claude-opus-4': 15.00,
};

const BURN_RATE_WINDOW = config.burn_rate_window_turns || 4;

// ── Helpers ───────────────────────────────────────────────────────────────────

function getContextLimit(model) {
  if (!model) return 200000;
  // Exact match
  if (CONTEXT_LIMITS[model]) return CONTEXT_LIMITS[model];
  // Prefix match
  for (const [key, val] of Object.entries(CONTEXT_LIMITS)) {
    if (model.startsWith(key) || key.startsWith(model)) return val;
  }
  return 200000;
}

function getModelPrice(model) {
  if (!model) return 3.00;
  if (MODEL_PRICES[model]) return MODEL_PRICES[model];
  for (const [key, val] of Object.entries(MODEL_PRICES)) {
    if (model.startsWith(key) || key.startsWith(model)) return val;
  }
  return 3.00;
}

/**
 * Estimate output tokens from assistant message content.
 * Claude streaming logs always report output_tokens=1 so we approximate from chars.
 */
function estimateOutputTokens(content) {
  if (!content) return 0;
  let totalChars = 0;
  if (typeof content === 'string') {
    totalChars = content.length;
  } else if (Array.isArray(content)) {
    for (const block of content) {
      if (block.type === 'text' && block.text) totalChars += block.text.length;
    }
  }
  return Math.round(totalChars / 3.5);
}

// ── Main parser ───────────────────────────────────────────────────────────────

function analyzeTranscript(transcriptPath, model) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) {
    return null;
  }

  const raw = fs.readFileSync(transcriptPath, 'utf8');
  const lines = raw.split('\n').filter(l => l.trim());

  const entries = [];
  for (const line of lines) {
    try {
      entries.push(JSON.parse(line));
    } catch (_) {
      // skip malformed lines
    }
  }

  // ── Detect model from transcript if not provided ──────────────────────────
  if (!model || model === 'unknown') {
    for (const e of entries) {
      if (e.message?.model) { model = e.message.model; break; }
      if (e.model) { model = e.model; break; }
    }
  }

  const tokensMax = getContextLimit(model);
  const pricePerM = getModelPrice(model);

  // ── Collect per-turn input token readings ─────────────────────────────────
  // We want the input_tokens from each assistant turn (the running total that Claude sees)
  const inputTokenReadings = []; // { turn, inputTokens, cacheReadTokens, cacheCreationTokens }
  let turnIndex = 0;
  let latestAssistantContent = null;
  let totalOutputTokensEstimate = 0;

  for (const entry of entries) {
    const msg = entry.message || entry;
    const role = msg.role || entry.role;

    if (role === 'assistant') {
      const usage = msg.usage || entry.usage || {};
      const inputTok = usage.input_tokens || 0;
      const cacheRead = usage.cache_read_input_tokens || 0;
      const cacheCreate = usage.cache_creation_input_tokens || 0;

      if (inputTok > 0) {
        turnIndex++;
        inputTokenReadings.push({
          turn: turnIndex,
          inputTokens: inputTok,
          cacheReadTokens: cacheRead,
          cacheCreationTokens: cacheCreate,
        });
      }

      // Track latest assistant content for output token estimation
      const content = msg.content || entry.content;
      if (content) {
        latestAssistantContent = content;
        totalOutputTokensEstimate += estimateOutputTokens(content);
      }
    } else if (role === 'user') {
      // count user turns too for age calculation
    }
  }

  // ── Compute stats from latest reading ────────────────────────────────────
  if (inputTokenReadings.length === 0) {
    return {
      tokens_used: 0,
      tokens_max: tokensMax,
      usage_pct: 0,
      burn_rate: 0,
      turns_left: null,
      estimated_cost_usd: 0,
      cache_efficiency: 0,
      total_turns: 0,
      model: model || 'unknown',
    };
  }

  const latest = inputTokenReadings[inputTokenReadings.length - 1];
  const tokensUsed = latest.inputTokens + totalOutputTokensEstimate;
  const usagePct = Math.min(100, (tokensUsed / tokensMax) * 100);

  // Burn rate: average delta of input_tokens across last N turns
  const window = inputTokenReadings.slice(-BURN_RATE_WINDOW);
  let burnRate = 0;
  if (window.length >= 2) {
    const deltas = [];
    for (let i = 1; i < window.length; i++) {
      const delta = window[i].inputTokens - window[i - 1].inputTokens;
      if (delta > 0) deltas.push(delta);
    }
    if (deltas.length > 0) {
      burnRate = Math.round(deltas.reduce((a, b) => a + b, 0) / deltas.length);
    }
  }

  const tokensRemaining = Math.max(0, tokensMax - tokensUsed);
  const turnsLeft = burnRate > 0 ? Math.floor(tokensRemaining / burnRate) : null;

  // Cache efficiency
  const totalCacheRead = inputTokenReadings.reduce((s, r) => s + r.cacheReadTokens, 0);
  const totalCacheCreate = inputTokenReadings.reduce((s, r) => s + r.cacheCreationTokens, 0);
  const totalInput = inputTokenReadings.reduce((s, r) => s + r.inputTokens, 0);
  const cacheEfficiency = (totalInput + totalCacheCreate) > 0
    ? totalCacheRead / (totalInput + totalCacheCreate)
    : 0;

  // Cost estimation (input only — output pricing is complex and model-specific)
  const estimatedCostUsd = (latest.inputTokens / 1_000_000) * pricePerM;

  return {
    tokens_used: tokensUsed,
    tokens_input: latest.inputTokens,
    tokens_output_est: totalOutputTokensEstimate,
    tokens_max: tokensMax,
    usage_pct: Math.round(usagePct * 10) / 10,
    burn_rate: burnRate,
    turns_left: turnsLeft,
    estimated_cost_usd: Math.round(estimatedCostUsd * 10000) / 10000,
    cache_efficiency: Math.round(cacheEfficiency * 100) / 100,
    total_turns: inputTokenReadings.length,
    model: model || 'unknown',
    _readings: inputTokenReadings,
  };
}

// ── CLI entry point ───────────────────────────────────────────────────────────

if (require.main === module) {
  const [,, transcriptPath, model, sessionId] = process.argv;

  if (!transcriptPath) {
    console.error('Usage: analyze.js <transcript_path> [model] [session_id]');
    process.exit(1);
  }

  const result = analyzeTranscript(transcriptPath, model);
  if (!result) {
    console.error(`Cannot read transcript: ${transcriptPath}`);
    process.exit(1);
  }

  // Strip internal _readings from output
  const { _readings, ...output } = result;
  console.log(JSON.stringify(output, null, 2));
}

module.exports = { analyzeTranscript };
