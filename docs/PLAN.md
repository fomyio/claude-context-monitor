# Implementation Plan — claude-context-monitor

## Goal

Build a Claude Code plugin (using the official Hooks API) that:
1. Tracks real-time context window token consumption per session
2. Uses `claude-haiku-4-5` to evaluate whether a new user prompt is semantically related to the current session context
3. Combines token pressure + semantic drift + task completion signals into a **compact score**
4. Injects proactive recommendations into Claude's context and sends macOS desktop notifications
5. Enriches `/compact` summaries with structured instructions so compacted sessions are recoverable

---

## Phase 1 — Core Token Tracker (MVP)

**Goal:** Hook into Claude Code, read JSONL logs, display token usage after every turn.

### Tasks

#### 1.1 `hooks/session-init.sh`
- Reads `SessionStart` hook JSON from stdin
- Extracts `session_id`, `model`, `transcript_path`
- Creates `state/<session_id>.json` with:
  ```json
  {
    "session_id": "...",
    "model": "claude-sonnet-4-6",
    "started_at": "2026-04-09T17:00:00Z",
    "token_history": [],
    "topics": [],
    "last_compact_at_turn": 0,
    "total_turns": 0
  }
  ```
- Checks CLAUDE.md size → warns if static overhead > 15% of model context limit

#### 1.2 `src/analyze.js`
Core engine. Inputs: `transcript_path`, `model`, `session_id`. Outputs JSON:
```json
{
  "tokens_used": 142000,
  "tokens_max": 200000,
  "usage_pct": 71.0,
  "burn_rate": 8200,
  "turns_left": 7,
  "estimated_cost_usd": 0.43,
  "cache_efficiency": 0.74,
  "total_turns": 18
}
```

Implementation steps:
- Read all JSONL lines, parse valid JSON entries
- Find latest assistant entry with `usage.input_tokens > 0`
- Estimate output tokens: sum all assistant `content` char lengths ÷ 3.5
- Compute burn rate: average delta of `input_tokens` across last 4 turns
- Compute cache_efficiency: `cache_read_tokens / (input_tokens + cache_creation_tokens)`
- Compute cost: `(input_tokens / 1M) * MODEL_INPUT_PRICE[model]`

#### 1.3 `hooks/update-state.sh` (async, Stop hook)
- Reads `Stop` hook JSON: extracts `last_assistant_message`, `transcript_path`, `session_id`
- Calls `analyze.js` to get latest stats
- Appends token reading to `state/<session_id>.json → token_history[]`
- Stores `last_assistant_message` in state (used by advisor for task completion detection)
- Increments `total_turns`

#### 1.4 `hooks/check.sh` (UserPromptSubmit — main orchestrator)
- Reads hook JSON from stdin
- Calls `analyze.js` — get token stats
- Renders visual token bar:
  ```
  [CTX] ████████████░░░░░░░░ 62% | ~9 turns left
  ```
- If `usage_pct <= 45%`: print bar to stdout, exit 0
- If `usage_pct > 45%`: pass control to `advisor.js`

#### 1.5 Register hooks in `~/.claude/settings.json`
Provide a `hooks/settings-snippet.json` that users merge into their settings.

#### 1.6 `hooks/post-compact.sh`
- Reads `PostCompact` hook JSON: `compact_summary`, `trigger`
- Resets token history in state file (tokens freed)
- Logs compact event: `{ compacted_at, pre_tokens, post_tokens, savings_pct }`
- Writes a desktop notification: "Compact complete — freed ~45% context"

**Deliverable:** Token bar appears after every user message. Passive, non-blocking.

---

## Phase 2 — Intelligence Layer

**Goal:** Add haiku relevance eval + smart compact score engine.

### Tasks

#### 2.1 `src/fingerprint.js`
Builds a minimal semantic fingerprint from the transcript for the haiku eval:
- Takes last N human turns (default 5), truncates each to 150 chars
- Takes last assistant message, truncates to 200 chars
- Produces a ~400-token document — never the full transcript

```javascript
function buildFingerprint(transcriptPath, maxTurns = 5) {
  // Returns string: "Recent turns:\nTurn 1: ...\nTurn 2: ...\nLast response: ..."
}
```

#### 2.2 `src/advisor.js`
Main intelligence engine:

**Step A: Task completion detection**
Regex pattern matching on `last_assistant_message` from state:
```javascript
const COMPLETION_PATTERNS = [
  /tests? (pass|passing|passed)/i,
  /successfully (merged|deployed|committed|pushed)/i,
  /pr (created|merged|opened)/i,
  /implementation (complete|done|finished)/i,
  /(fixed|resolved|closed) (the )?(issue|bug|error)/i,
  /feel free to (ask|continue)/i,
];
// score >= 2 → 'complete', score === 1 → 'partial', else 'ongoing'
```

**Step B: Haiku relevance eval**
Only runs if `usage_pct > config.relevance_eval_threshold_pct` (default 45%):
```javascript
const result = await anthropic.messages.create({
  model: 'claude-haiku-4-5',
  max_tokens: 60,
  messages: [{ role: 'user', content: RELEVANCE_PROMPT(fingerprint, newPrompt) }]
});
// Returns: { score: 0.0-1.0, label: "related|drifted|unrelated", reason: "..." }
```

**Step C: Compact score computation**
```
compact_score =
  token_pressure_pts  (0–40)  based on usage_pct thresholds
+ relevance_drift_pts (0–30)  based on haiku label
+ task_complete_pts   (0–20)  based on completion detection
+ age_pts             (0–10)  based on turns since last compact
```

**Step D: Decision + output**
| Score | Action |
|---|---|
| 0–25 | Print token bar, exit 0 |
| 26–45 | Print bar + suggestion text, exit 0 |
| 46–65 | Print urgent suggestion + send notification, exit 0 |
| 66–80 | Print block warning + send urgent notification, exit 0 |
| 80+ | Print block message to stderr + exit 2 (blocks prompt) |

#### 2.3 `hooks/notify.sh`
Platform-aware desktop notifications:
```bash
# macOS
osascript -e "display notification \"$MSG\" with title \"$TITLE\""
# Linux (notify-send)
notify-send "$TITLE" "$MSG"
```

Notification levels:
- `info`: 70% usage (banner)  
- `warning`: 85% usage (badge + sound)
- `critical`: 95% or compact_score > 80 (alert + sound)
- `golden`: task complete + unrelated prompt (banner — "Perfect time to compact")

#### 2.4 Topic segmentation in state
When haiku returns `unrelated`, log a topic boundary to state:
```json
{
  "topics": [
    { "start_turn": 1, "end_turn": 12, "label": "Auth module setup", "tokens": 45200 },
    { "start_turn": 13, "end_turn": "current", "label": "CI failures", "tokens": 71000 }
  ]
}
```
The `label` field is populated from the haiku `reason` field.

**Deliverable:** Semantic-aware compact suggestions. Golden moment detection. Desktop notifications.

---

## Phase 3 — Advanced Features

### 3.1 `hooks/pre-compact.sh` — Enriched Compact Instructions
When `PreCompact` fires, output structured JSON to inject custom compact instructions:
```bash
echo '{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "customInstructions": "Preserve in your summary: all file paths modified, exact error messages, git branch name, PR numbers, any env variables or config values discussed. Format as a structured list."
  }
}'
```

### 3.2 `src/dashboard.js` — CLI Report
A `context-monitor report` command that shows:
```
Session: 18 turns | 47 min | claude-sonnet-4-6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Context:  ████████████████░░░░  78%  (156,000/200,000)
Cost:     ~$0.47 this session  |  Cache saved: ~$0.31  (cache efficiency: 74%)
Burn:     ~8,200 tokens/turn   |  ~4 turns remaining
Topics:   [Auth setup → CI failures → ?]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Recommendation: HIGH compact score (72). New prompt appears unrelated.
```

### 3.3 CLAUDE.md Bloat Detector (SessionStart)
In `session-init.sh`, compute size of CLAUDE.md and all `@import`-ed files.
- Estimate token count (chars ÷ 3.5)
- If > 15% of model limit: warn user
- Log to state for dashboard display

### 3.4 Auto-compact Mode (opt-in)
In `config.json`: `"auto_compact_enabled": false`
When `compact_score > config.auto_compact_threshold_pct` AND user opt-in:
- Use `UserPromptSubmit` `decision: "block"` with `reason: "[Auto-compact running...]"`
- Trigger compact via shell (not directly possible via hooks — surface as instruction to Claude)

### 3.5 Tmux Status Bar Integration
Write stats to a named pipe / temp file. User adds to `.tmux.conf`:
```
set -g status-right '#(cat /tmp/claude-ctx-status 2>/dev/null)'
```
`update-state.sh` writes: `CTX 78% | ~4 turns | $0.47`

---

## Configuration Reference (`config.json`)

```json
{
  "relevance_eval_enabled": true,
  "relevance_eval_threshold_pct": 45,
  "anthropic_api_key_cmd": "cat ~/.anthropic_key",
  "context_limits": {
    "claude-opus-4": 200000,
    "claude-sonnet-4-6": 200000,
    "claude-haiku-4-5": 200000
  },
  "model_prices_per_million_input": {
    "claude-opus-4": 5.00,
    "claude-sonnet-4-6": 3.00,
    "claude-haiku-4-5": 1.00
  },
  "notify_thresholds": {
    "info": 70,
    "warning": 85,
    "critical": 95
  },
  "compact_score_thresholds": {
    "suggest": 26,
    "warn": 46,
    "urgent": 66,
    "block": 80
  },
  "block_on_critical": false,
  "auto_compact_enabled": false,
  "auto_compact_threshold_score": 85,
  "tmux_status_enabled": false,
  "tmux_status_file": "/tmp/claude-ctx-status",
  "fingerprint_max_turns": 5,
  "state_dir": "~/.claude/plugins/context-monitor/state"
}
```

---

## Hook Registration (`hooks/settings-snippet.json`)

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{ "type": "command", "command": "~/.claude/plugins/context-monitor/hooks/session-init.sh" }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{ "type": "command", "command": "~/.claude/plugins/context-monitor/hooks/check.sh" }]
    }],
    "Stop": [{
      "hooks": [{ "type": "command", "command": "~/.claude/plugins/context-monitor/hooks/update-state.sh", "background": true }]
    }],
    "PreCompact": [{
      "hooks": [{ "type": "command", "command": "~/.claude/plugins/context-monitor/hooks/pre-compact.sh" }]
    }],
    "PostCompact": [{
      "hooks": [{ "type": "command", "command": "~/.claude/plugins/context-monitor/hooks/post-compact.sh" }]
    }]
  }
}
```

---

## Testing Strategy

### Unit Tests
- `analyze.js` with mock JSONL files (various scenarios: fresh session, mid-session, post-compact)
- `advisor.js` compact score calculator with fixture inputs
- `fingerprint.js` with long transcripts — verify token budget

### Integration Tests
- Mock a full session lifecycle: SessionStart → 5× (UserPromptSubmit + Stop) → PostCompact → 3× more turns
- Verify state file correctly tracks token history
- Verify haiku eval is called only above threshold

### End-to-End
- Run a real Claude Code session with the plugin active
- Verify token bar appears after every turn
- Trigger a topic shift and confirm notification fires
- Run `/compact` and verify savings are logged

---

## Milestones & Time Estimates

| Phase | Key Output | Est. Time |
|---|---|---|
| Phase 1: Core MVP | Token bar, burn rate, state tracking | 3–4 hrs |
| Phase 2: Intelligence | Haiku eval, compact score, notifications | 3–4 hrs |
| Phase 3: Advanced | Dashboard, PreCompact enrichment, tmux bar | 4–6 hrs |
| **Total** | **Full-featured plugin** | **~12 hrs** |

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Use JSONL `input_tokens` as primary signal | Most reliable value in the log; actual API usage from last call |
| Estimate output tokens from char count | `output_tokens` in logs is always `1` (streaming artifact) |
| Send fingerprint not full transcript to haiku | Keeps eval cost to ~$0.0005/turn; full transcript would be expensive |
| Exit 0 from most hooks | Plugin should NEVER block the user unless compact_score > 80 |
| Inject status into stdout (not stderr) | Claude Code appends stdout to LLM context — Claude becomes self-aware |
| Store state in local JSON files | Simple, portable, no dependencies; survives Claude restarts |
