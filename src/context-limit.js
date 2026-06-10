/**
 * context-limit.js — single source of truth for resolving a model's context
 * window size.
 *
 * Consumed by analyze.js, dashboard.js, hooks/session-init.sh, and the inline
 * node block in src/statusline.sh. Keep every limit rule here: the same logic
 * hand-copied across those sites has drifted before (session-init.sh lost the
 * [1m] branch and pinned 1M sessions to 200K thresholds).
 */

'use strict';

const DEFAULT_LIMIT = 200000;
const LIMIT_1M = 1000000;

// The 1M-context variants carry a '[1m]' suffix on the model id
// (e.g. 'claude-opus-4-8[1m]'). Keyed on the id only: it's the canonical
// signal, and a looser display-name match (e.g. /1m\b/) would false-positive
// on names that merely end in "1m".
function is1MModel(modelId) {
  return /\[1m\]/i.test(modelId || '');
}

// Resolve from a live payload-reported window size (statusline path). The
// [1m] floor wins over an absent/narrower report — Claude Code's payload
// doesn't always carry the widened size — otherwise trust the report and
// fall back to the 200K default.
function resolveLimit(modelId, reportedLimit) {
  if (is1MModel(modelId)) return Math.max(LIMIT_1M, reportedLimit || 0);
  return reportedLimit || DEFAULT_LIMIT;
}

// Resolve from a static config table (no live report available). Exact id
// match first, then family prefix (e.g. 'claude-opus-4-7-20250101' →
// 'claude-opus-4-7'). We do NOT match the other direction
// (key.startsWith(modelId)), or a short/unknown id like 'claude' would
// silently inherit the first table entry's value.
// On a total miss returns `fallback` (DEFAULT_LIMIT unless overridden) —
// callers with a better last resort than the default (e.g. dashboard.js
// reconstructing the limit from recorded usage) pass null to detect the miss.
function lookupLimit(modelId, table, fallback = DEFAULT_LIMIT) {
  if (is1MModel(modelId)) return LIMIT_1M;
  if (!modelId) return fallback;
  const limits = table || {};
  if (limits[modelId] != null) return limits[modelId];
  for (const [key, val] of Object.entries(limits)) {
    if (modelId.startsWith(key)) return val;
  }
  return fallback;
}

module.exports = { is1MModel, resolveLimit, lookupLimit, DEFAULT_LIMIT, LIMIT_1M };
