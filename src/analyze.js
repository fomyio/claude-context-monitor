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
  'claude-opus-4-8': 200000,
  'claude-opus-4-7': 200000,
  'claude-opus-4-6': 200000,
  'claude-opus-4-5': 200000,
  'claude-opus-4': 200000,
  'claude-sonnet-4-6': 200000,
  'claude-sonnet-4-5': 200000,
  'claude-haiku-4-5': 200000,
};

const MODEL_PRICES = config.model_prices_per_million_input || {
  'claude-opus-4-8': 15.00,
  'claude-opus-4-7': 15.00,
  'claude-opus-4-6': 15.00,
  'claude-opus-4-5': 15.00,
  'claude-opus-4': 15.00,
  'claude-sonnet-4-6': 3.00,
  'claude-sonnet-4-5': 3.00,
  'claude-haiku-4-5': 0.80,
};

const BURN_RATE_WINDOW = config.burn_rate_window_turns || 4;

// ── Helpers ───────────────────────────────────────────────────────────────────

function getContextLimit(model, sessionId) {
  // 1. State file — written by statusline.sh with Claude Code's real limit (ground truth)
  if (sessionId) {
    try {
      const stateDirCfg = config.state_dir || '~/.claude/plugins/context-monitor/state';
      const stateDir = stateDirCfg.replace(/^~/, process.env.HOME || '~');
      const state = JSON.parse(fs.readFileSync(path.join(stateDir, sessionId + '.json'), 'utf8'));
      if (state.context_limit > 0) return state.context_limit;
    } catch (_) {}
  }
  // 2. The 1M-context variants carry a '[1m]' suffix on the model id
  // (e.g. 'claude-opus-4-8[1m]'). Detect it before the static table, which only
  // knows base 200K limits — otherwise the family-prefix match below would pin
  // a 1M session to 200K.
  if (model && /\[1m\]/i.test(model)) return 1000000;
  // 3. config.json static table
  if (!model) return 200000;
  if (CONTEXT_LIMITS[model]) return CONTEXT_LIMITS[model];
  // Match by family prefix only (e.g. "claude-opus-4-7-20250101" → "claude-opus-4-7").
  // We do NOT match the other direction (key.startsWith(model)), or a short/unknown
  // id like "claude" would silently inherit the first table entry's value.
  for (const [key, val] of Object.entries(CONTEXT_LIMITS)) {
    if (model.startsWith(key)) return val;
  }
  return 200000;
}

function getModelPrice(model) {
  if (!model) return 3.00;
  if (MODEL_PRICES[model]) return MODEL_PRICES[model];
  // Prefix-only match (see getContextLimit) — an unknown model falls through to
  // the default rather than being mispriced as the first (Opus) table entry.
  for (const [key, val] of Object.entries(MODEL_PRICES)) {
    if (model.startsWith(key)) return val;
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

function analyzeTranscript(transcriptPath, model, sessionId) {
  let groundTruth = null;

  // ── Prefer ground-truth context_window data from statusline.sh ──────────────
  // statusline.sh receives accurate used_tokens/used_percentage from Claude Code.
  // Use these when available because the transcript's usage data does not include
  // system prompts, tool definitions, or injected status-line text.
  if (sessionId) {
    try {
      const stateDirCfg = config.state_dir || '~/.claude/plugins/context-monitor/state';
      const stateDir = stateDirCfg.replace(/^~/, process.env.HOME || '~');
      const state = JSON.parse(fs.readFileSync(path.join(stateDir, sessionId + '.json'), 'utf8'));
      if (state.used_tokens != null) {
        // Floor the limit at 1M for '[1m]'-suffixed (1M-context) models, even if
        // the stored context_limit is a stale 200K written before this fix.
        const is1M = /\[1m\]/i.test(state.model || model || '');
        let limit = state.context_limit || null;
        if (is1M) limit = Math.max(1000000, limit || 0);
        let pct = state.used_percentage;
        // Recompute from the token ratio when the stored percentage is missing, a
        // stale 0 while tokens are positive, or when we just widened the limit to
        // 1M (the stored pct was computed against the old 200K limit and is now
        // wrong). Defends against old state files / a statusline render that
        // lacked used_percentage.
        if ((pct == null || pct <= 0 || is1M) && state.used_tokens > 0 && limit) {
          pct = (state.used_tokens / limit) * 100;
        }
        if (pct != null) {
          groundTruth = {
            used_tokens: state.used_tokens,
            used_percentage: pct,
            context_limit: limit,
          };
        }
      }
    } catch (_) {}
  }

  if (!transcriptPath || !fs.existsSync(transcriptPath)) {
    // No transcript, but we might still have ground truth from statusline
    if (groundTruth) {
      const tokensMax = groundTruth.context_limit || getContextLimit(model, sessionId);
      return {
        tokens_used: groundTruth.used_tokens,
        tokens_input: groundTruth.used_tokens,
        tokens_output_est: 0,
        tokens_max: tokensMax,
        usage_pct: Math.round(groundTruth.used_percentage * 10) / 10,
        burn_rate: 0,
        turns_left: null,
        estimated_cost_usd: 0,
        cache_efficiency: 0,
        total_turns: 0,
        model: model || 'unknown',
      };
    }
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

  const tokensMax = getContextLimit(model, sessionId);
  const pricePerM = getModelPrice(model);

  // ── Collect per-turn input token readings ─────────────────────────────────
  // Total context = input_tokens + cache_read_input_tokens + cache_creation_input_tokens
  // With prompt caching, input_tokens only reports the uncached portion (often 0 or 1),
  // while the bulk of context sits in cache_read_input_tokens.
  const inputTokenReadings = []; // { turn, totalInputTokens, inputTokens, cacheReadTokens, cacheCreationTokens }
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
      const totalInput = inputTok + cacheRead + cacheCreate;

      if (totalInput > 0) {
        turnIndex++;
        inputTokenReadings.push({
          turn: turnIndex,
          totalInputTokens: totalInput,
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
      tokens_input: 0,
      tokens_output_est: 0,
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
  // Total context = all input tokens (uncached + cache_read + cache_creation) + output estimate
  const tokensUsed = latest.totalInputTokens + totalOutputTokensEstimate;
  const usagePct = Math.min(100, (tokensUsed / tokensMax) * 100);

  // Burn rate: average delta of total input tokens across last N turns
  const window = inputTokenReadings.slice(-BURN_RATE_WINDOW);
  let burnRate = 0;
  if (window.length >= 2) {
    const deltas = [];
    for (let i = 1; i < window.length; i++) {
      const delta = window[i].totalInputTokens - window[i - 1].totalInputTokens;
      if (delta > 0) deltas.push(delta);
    }
    if (deltas.length > 0) {
      burnRate = Math.round(deltas.reduce((a, b) => a + b, 0) / deltas.length);
    }
  }

  const tokensRemaining = Math.max(0, tokensMax - tokensUsed);
  const turnsLeft = burnRate > 0 ? Math.floor(tokensRemaining / burnRate) : null;

  // Cache efficiency: how much of total input is served from cache
  const totalCacheRead = inputTokenReadings.reduce((s, r) => s + r.cacheReadTokens, 0);
  const totalAllInput = inputTokenReadings.reduce((s, r) => s + r.totalInputTokens, 0);
  const cacheEfficiency = totalAllInput > 0 ? totalCacheRead / totalAllInput : 0;

  // Cost estimation with per-type token pricing:
  // cache_read ≈ 10% of input price, cache_creation ≈ 125% of input price
  const cacheReadPrice = pricePerM * 0.1;
  const cacheWritePrice = pricePerM * 1.25;
  const estimatedCostUsd =
    (latest.inputTokens / 1_000_000) * pricePerM +
    (latest.cacheReadTokens / 1_000_000) * cacheReadPrice +
    (latest.cacheCreationTokens / 1_000_000) * cacheWritePrice;

  // ── Override with ground truth from statusline.sh when available ───────────
  // Claude Code's context_window includes system prompts, tool defs, and injected
  // text that the transcript usage data cannot see. Use the authoritative numbers.
  let finalTokensUsed = tokensUsed;
  let finalTokensInput = latest.totalInputTokens;
  let finalTokensMax = tokensMax;
  let finalUsagePct = usagePct;
  if (groundTruth) {
    finalTokensUsed = groundTruth.used_tokens;
    finalTokensInput = groundTruth.used_tokens;
    finalTokensMax = groundTruth.context_limit || tokensMax;
    // Prefer Claude Code's authoritative percentage; only recompute from the
    // token ratio if it is missing. Clamp to 100 either way.
    finalUsagePct = Math.min(100, groundTruth.used_percentage != null
      ? groundTruth.used_percentage
      : (groundTruth.used_tokens / finalTokensMax) * 100);
  }
  const finalTokensRemaining = Math.max(0, finalTokensMax - finalTokensUsed);
  const finalTurnsLeft = burnRate > 0 ? Math.floor(finalTokensRemaining / burnRate) : turnsLeft;

  return {
    tokens_used: finalTokensUsed,
    tokens_input: finalTokensInput,
    tokens_output_est: totalOutputTokensEstimate,
    tokens_max: finalTokensMax,
    usage_pct: Math.round(finalUsagePct * 10) / 10,
    burn_rate: burnRate,
    turns_left: finalTurnsLeft,
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

  const result = analyzeTranscript(transcriptPath, model, sessionId);
  if (!result) {
    console.error(`Cannot read transcript: ${transcriptPath}`);
    process.exit(1);
  }

  // Strip internal _readings from output
  const { _readings, ...output } = result;
  console.log(JSON.stringify(output, null, 2));
}

module.exports = { analyzeTranscript };
