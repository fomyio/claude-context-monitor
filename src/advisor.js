#!/usr/bin/env node
/**
 * advisor.js — Haiku relevance eval + compact score engine
 *
 * Invoked by check.sh when usage exceeds the relevance_eval_threshold.
 * Reads config, executes Anthropic API call with the footprint, computes a final
 * compact score, and decides the next action (allow/block/etc).
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { Anthropic } = require('@anthropic-ai/sdk');
const { buildFingerprint } = require('./fingerprint');

// ── Parse Args ───────────────────────────────────────────────────────────────

let args = {};
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i].startsWith('--')) {
    const key = process.argv[i].substring(2);
    const val = process.argv[i + 1] || '';
    args[key] = val;
    i++;
  }
}

const {
  transcript,
  session,
  prompt: newPrompt = '',
  stats: statsStr = '{}',
  'state-file': stateFile = '',
  config: configPath = '',
} = args;

// ── Load Config & State ──────────────────────────────────────────────────────

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (_) {}

let state = {};
try {
  if (stateFile) {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  }
} catch (_) {}

let stats = {};
try {
  stats = JSON.parse(statsStr);
} catch (_) {}

// ── Helpers ──────────────────────────────────────────────────────────────────

function getApiKey() {
  // 1. Environment variable (inherited from Claude Code session)
  if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY;
  // 2. Fallback to configured command (e.g. cat ~/.anthropic_key)
  const cmd = config.anthropic_api_key_cmd || 'cat ~/.anthropic_key';
  try {
    return execSync(cmd, { stdio: ['ignore', 'pipe', 'ignore'], encoding: 'utf8' }).trim();
  } catch (err) {
    return null;
  }
}

function detectTaskCompletion(lastAssistantMsg) {
  if (!lastAssistantMsg) return { status: 'ongoing', pts: 0 };
  
  const COMPLETION_PATTERNS = [
    /tests? (pass|passing|passed)/i,
    /successfully (merged|deployed|committed|pushed)/i,
    /pr (created|merged|opened)/i,
    /implementation (complete|done|finished)/i,
    /(fixed|resolved|closed) (the )?(issue|bug|error)/i,
    /feel free to (ask|continue|let me know)/i,
    /all set/i,
  ];

  let matches = 0;
  for (const pat of COMPLETION_PATTERNS) {
    if (pat.test(lastAssistantMsg)) matches++;
  }

  if (matches >= 2) return { status: 'complete', pts: 20 };
  if (matches === 1) return { status: 'partial', pts: 10 };
  return { status: 'ongoing', pts: 0 };
}

// ── Evaluation Engine ────────────────────────────────────────────────────────

async function runHaikuEval(fingerprint, newPrompt, apiKey) {
  if (!apiKey) {
    return { score: 0, label: 'unknown', reason: 'No API key available for eval' };
  }

  const anthropic = new Anthropic({ apiKey });

  const RELEVANCE_PROMPT = \`
You are an intelligent observer analyzing a conversation with an AI assistant.
Your goal is to determine if the user's NEW PROMPT is a continuation of the same 
technical task/context, OR if it represents a shift to a new, unrelated topic.

Here is a summary of the recent conversation context:
<context>
\${fingerprint}
</context>

Here is the user's new prompt:
<new_prompt>
\${newPrompt}
</new_prompt>

Respond in strict JSON with no other text. Format:
{
  "relatedness_score": 0.0 to 1.0,  // 1.0 = exactly the same task, 0.0 = completely different
  "label": "related" | "drifted" | "unrelated",
  "reason": "short 1-sentence reason"
}
\`;

  try {
    const msg = await anthropic.messages.create({
      model: 'claude-haiku-4-5',
      max_tokens: 60,
      temperature: 0,
      messages: [{ role: 'user', content: RELEVANCE_PROMPT }]
    });

    const responseText = msg.content[0].text;
    const jsonMatch = responseText.match(/\\{.*\\}/s);
    if (!jsonMatch) throw new Error('Invalid JSON from eval');
    
    const result = JSON.parse(jsonMatch[0]);
    return {
      score: result.relatedness_score,
      label: result.label,
      reason: result.reason
    };
  } catch (err) {
    // Fail semi-silently so we don't break the flow
    return { score: 0.5, label: 'unknown', reason: \`Eval failed: \${err.message}\` };
  }
}

// ── Main Pipeline ────────────────────────────────────────────────────────────

async function main() {
  if (!transcript || !stats.usage_pct) {
    console.log(JSON.stringify({ action: 'allow', output: '', compact_score: 0 }));
    return;
  }

  // 1. Token Pressure (0-40 pts)
  let tokenPts = 0;
  if (stats.usage_pct >= 95) tokenPts = 40;
  else if (stats.usage_pct >= 85) tokenPts = 30;
  else if (stats.usage_pct >= 70) tokenPts = 20;
  else if (stats.usage_pct >= 45) tokenPts = 10;

  // 2. Task Completion (0-20 pts)
  const completion = detectTaskCompletion(state.last_assistant_message || '');
  const taskPts = completion.pts;

  // 3. Relevance Drift via Haiku (0-30 pts)
  let driftPts = 0;
  let evalResult = null;
  
  if (newPrompt && newPrompt.trim()) {
    const fingerprint = buildFingerprint(transcript, config.fingerprint_max_turns || 5);
    const apiKey = getApiKey();
    evalResult = await runHaikuEval(fingerprint, newPrompt, apiKey);
    
    if (evalResult.label === 'unrelated') driftPts = 30;
    else if (evalResult.label === 'drifted') driftPts = 15;
    else if (evalResult.label === 'unknown') driftPts = 0;
    // related = 0
  }

  // 4. Age / Turns since last compact (0-10 pts)
  let agePts = 0;
  const turnsSinceCompact = (state.total_turns || 0) - (state.last_compact_at_turn || 0);
  if (turnsSinceCompact >= 30) agePts = 10;
  else if (turnsSinceCompact >= 15) agePts = 5;
  else if (turnsSinceCompact >= 8) agePts = 2;

  const totalScore = tokenPts + taskPts + driftPts + agePts;

  // 5. Decision & Output Formatting
  const thresholds = config.compact_score_thresholds || {
    suggest: 26, warn: 46, urgent: 66, block: 80
  };

  let action = 'allow';
  let outputText = '';

  if (totalScore >= thresholds.block) {
    action = 'block';
    outputText = \`[CTX] 🛑 COMPACT REQUIRED (Score \${totalScore}). Context limit imminent or complete topic shift.\`;
  } else if (totalScore >= thresholds.urgent) {
    outputText = \`[CTX] 🚨 URGENT: Strongly recommend running /compact now (Score \${totalScore}).\`;
  } else if (totalScore >= thresholds.warn) {
    outputText = \`[CTX] ⚠️  Warning: Good time to /compact soon (Score \${totalScore}).\`;
  } else if (totalScore >= thresholds.suggest) {
    let rationale = '';
    if (driftPts > 0) rationale = evalResult ? evalResult.reason : 'Topic drift detected';
    else if (taskPts > 0) rationale = 'Task appears complete';
    else rationale = 'Context pressure rising';
    
    outputText = \`[CTX] 💡 Suggestion: You might want to /compact (\${rationale})\`;
  }

  // 6. Save state for smart compact instructions (single write)
  if (stateFile) {
    try {
      // Track topic boundary shifts
      if (evalResult && (evalResult.label === 'unrelated' || evalResult.label === 'drifted')) {
        state.topics = state.topics || [];
        state.topics.push({
          turn: state.total_turns + 1,
          label: evalResult.reason,
          shift_type: evalResult.label   // 'unrelated' | 'drifted'
        });
      }

      // Persist active task state for pre-compact.sh
      state.active_task = {
        completion_status: completion.status, // 'complete' | 'partial' | 'ongoing'
        topic_label: evalResult ? evalResult.reason : null,
        topic_relevance: evalResult ? evalResult.label : null, // 'related' | 'drifted' | 'unrelated'
        compact_score: totalScore,
        updated_at: new Date().toISOString(),
      };

      fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
    } catch (_) {}
  }

  console.log(JSON.stringify({
    compact_score: totalScore,
    action,
    output: outputText,
    eval: evalResult
  }));
}

main().catch(err => {
  // Fail-safe
  console.log(JSON.stringify({ action: 'allow', output: '', compact_score: 0 }));
});
