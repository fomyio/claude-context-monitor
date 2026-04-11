#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact hook (Smart Compact Instructions)
#
# Injects dynamic, context-aware instructions into the compact summarization
# prompt. Unlike the original static policy, this version:
#
#   1. Carries forward the previous compact summary (solves cumulative amnesia)
#   2. Marks stale vs active topics (solves "what to keep/drop")
#   3. Preserves active task state (solves "what matters now")
#   4. Signals task completion (solves "safe to drop stale context")
#
# Reads from the per-session state file written by advisor.js, check.sh,
# and post-compact.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"

# ── Read hook input ────────────────────────────────────────────────────────────
INPUT="$(cat)"

SESSION_ID="$(echo "$INPUT" | node -e "
  const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  console.log(d.session_id ?? d.sessionId ?? '');
" 2>/dev/null || echo '')"

if [ -z "$SESSION_ID" ]; then
  # No session context — fall back to static policy
  cat << 'FALLBACK'
Context Monitor Policy: When summarizing this session, please explicitly preserve:
1. All absolute and relative file paths that have been modified or discussed.
2. Any specific error messages we are currently trying to fix.
3. Important environment variables, config values, or port numbers.
4. Output these as a structured list at the top or bottom of your summary.
FALLBACK
  exit 0
fi

# ── Resolve state file ─────────────────────────────────────────────────────────
STATE_DIR_CFG="$(node -e "
  const c=JSON.parse(require('fs').readFileSync('$CONFIG','utf8'));
  console.log(c.state_dir ?? '~/.claude/plugins/context-monitor/state');
" 2>/dev/null || echo "~/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/\~/$HOME}"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

if [ ! -f "$STATE_FILE" ]; then
  # No state — fall back to static policy
  cat << 'FALLBACK'
Context Monitor Policy: When summarizing this session, please explicitly preserve:
1. All absolute and relative file paths that have been modified or discussed.
2. Any specific error messages we are currently trying to fix.
3. Important environment variables, config values, or port numbers.
4. Output these as a structured list at the top or bottom of your summary.
FALLBACK
  exit 0
fi

# ── Build dynamic compact instructions ─────────────────────────────────────────
# Uses node to read the state file and produce the instruction block, avoiding
# shell escaping issues with the compact summary content.
node -e "
  const fs = require('fs');
  let state;
  try {
    state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
  } catch(_) {
    // Fall back to static policy
    console.log(\`Context Monitor Policy: When summarizing this session, please explicitly preserve:
1. All absolute and relative file paths that have been modified or discussed.
2. Any specific error messages we are currently trying to fix.
3. Important environment variables, config values, or port numbers.
4. Output these as a structured list at the top or bottom of your summary.\`);
    process.exit(0);
  }

  const lines = [];

  // ── Section 1: Core preservation policy (always present) ────────────────
  lines.push('=== SMART COMPACT INSTRUCTIONS ===');
  lines.push('');
  lines.push('When summarizing this session, you MUST explicitly preserve:');
  lines.push('1. All absolute and relative file paths that have been modified or discussed.');
  lines.push('2. Any specific error messages we are currently trying to fix.');
  lines.push('3. Important environment variables, config values, or port numbers.');
  lines.push('4. Output these as a structured list at the top or bottom of your summary.');
  lines.push('');

  // ── Section 2: Previous compact summary (carry-forward) ────────────────
  // This is the key innovation: each compact preserves the summary from the
  // previous compact, creating a cumulative memory chain that prevents the
  // exponential fidelity loss documented in anthropics/claude-code#33212.
  const prevSummary = state.last_compact_summary || '';
  if (prevSummary.length > 0) {
    lines.push('--- PREVIOUS COMPACT SUMMARY (PRESERVE VERBATIM) ---');
    lines.push('This is a summary from a previous compaction in this session.');
    lines.push('You MUST include this content in your new summary under a');
    lines.push('\"Historical Context\" section. Do NOT discard or paraphrase it.');
    lines.push('');
    lines.push(prevSummary);
    lines.push('');
  }

  // ── Section 3: Topic awareness ──────────────────────────────────────────
  // The advisor tracks topic shifts via Haiku eval. We use that data to tell
  // the compact prompt which topics are stale (safe to summarize aggressively)
  // vs active (must be preserved in detail).
  const topics = state.topics || [];
  if (topics.length > 0) {
    lines.push('--- TOPIC HISTORY ---');
    lines.push('Topic shifts detected during this session:');
    topics.forEach((t, i) => {
      const typeTag = t.shift_type ? \` [\${t.shift_type}]\` : '';
      lines.push(\`  [\${i + 1}] Turn \${t.turn}\${typeTag}: \${t.label}\`);
    });
    lines.push('');

    // The most recent topic is the active one
    const activeTopic = topics[topics.length - 1];
    if (topics.length > 1) {
      const staleTopics = topics.slice(0, -1);
      lines.push(\`Active topic: \${activeTopic.label} (preserve in FULL detail)\`);
      lines.push(\`Stale topics: \${staleTopics.map(t => t.label).join(', ')}\`);
      lines.push('For stale topics: summarize AGGRESSIVELY — keep only final');
      lines.push('decisions and outcomes. Drop intermediate reasoning and debugging steps.');
    } else {
      lines.push(\`Active topic: \${activeTopic.label} (preserve in FULL detail)\`);
    }
    lines.push('');
  }

  // ── Section 4: Active task state ────────────────────────────────────────
  // Saved by advisor.js on each run: completion status, relevance, compact score.
  const activeTask = state.active_task || null;
  if (activeTask) {
    lines.push('--- CURRENT TASK STATE ---');

    if (activeTask.completion_status === 'complete') {
      lines.push('Task status: COMPLETE');
      lines.push('The previous task appears finished. It is SAFE to compact its');
      lines.push('details aggressively — preserve only the final decisions, files');
      lines.push('modified, and outcomes. Drop intermediate debugging and reasoning.');
    } else if (activeTask.completion_status === 'partial') {
      lines.push('Task status: PARTIALLY COMPLETE');
      lines.push('Some milestones are done but work continues. Preserve the');
      lines.push('completed outcomes AND the in-progress state in equal detail.');
    } else {
      lines.push('Task status: IN PROGRESS');
      lines.push('The current task is still ongoing. Do NOT compact away the');
      lines.push('active debugging state, intermediate findings, or work-in-progress.');
      lines.push('Preserve the full chain of reasoning and file modifications.');
    }

    if (activeTask.topic_relevance === 'unrelated') {
      lines.push('');
      lines.push('Topic shift: UNRELATED to previous context.');
      lines.push('The user has started a new topic. Previous context is STALE.');
      lines.push('Summarize the old topic aggressively, focus detail on the new topic.');
    } else if (activeTask.topic_relevance === 'drifted') {
      lines.push('');
      lines.push('Topic shift: DRIFTED from previous context.');
      lines.push('Loosely related but different focus. Preserve the connection');
      lines.push('but compress the earlier focus more aggressively.');
    }

    lines.push('');
  }

  // ── Section 5: Compact history ──────────────────────────────────────────
  // How many compactions have happened — signals cumulative quality risk.
  const compactCount = (state.compact_events || []).length;
  if (compactCount > 0) {
    lines.push('--- COMPACTION HISTORY ---');
    lines.push(\`This session has been compacted \${compactCount} time(s) before.\`);
    if (compactCount >= 3) {
      lines.push('WARNING: Multiple compactions cause cumulative context loss.');
      lines.push('Be EXTRA thorough in preserving key decisions, file paths, and');
      lines.push('user-stated constraints. Include the Historical Context section.');
    }
    lines.push('');
  }

  // ── Closing instruction ─────────────────────────────────────────────────
  lines.push('=== END SMART COMPACT INSTRUCTIONS ===');

  console.log(lines.join('\\n'));
" 2>/dev/null

exit 0
