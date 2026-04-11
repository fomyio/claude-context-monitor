<div align="center">

# claude-context-monitor

**Stop losing work to silent context overflows.**

A Claude Code plugin that watches your context window in real-time, predicts when you'll hit the limit, and tells you *before* it's too late.

[![Version](https://img.shields.io/badge/version-1.0.2-blue)](https://github.com/fomyio/claude-context-monitor/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D18-brightgreen)](https://nodejs.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](#)

</div>

---

## The problem

Claude Code's context window is 200,000 tokens. When it fills up, your session ends abruptly — in the middle of a refactor, a debug session, a long conversation. You get no warning. You just hit a wall.

And even when you *know* to compact, you don't know *when*. Compacting too early wastes a good session. Compacting too late means losing context you needed.

**This plugin solves both problems.**

---

## What it does

Every time you send a message, the plugin runs silently in the background and injects a status line into Claude's context:

```
[CTX] 🟢 [████░░░░░░░░░░░░░░░░] 22.1% | 44K/200K | ~124 turns left
```

As your session grows, it gets smarter. Above 45% usage it activates a semantic evaluation — it sends a lightweight fingerprint of your recent conversation to Claude Haiku (~200 tokens, ~$0.0005) and asks: *is this new prompt related to what we've been doing, or is this a fresh topic?*

If you're starting something new while context is already high, it tells you:

```
[CTX] 💡 Suggestion: You might want to /compact (Topic drift detected)
[CTX] ⚠️  Warning: Good time to /compact soon (Score 47)
[CTX] 🚨 URGENT: Strongly recommend running /compact now (Score 71)
```

It also sends desktop notifications at 70%, 85%, and 95% — so you're never caught off guard even when you're not looking at the terminal.

---

## How the scoring works

Every prompt is scored across four signals:

| Signal | Points | What it measures |
|--------|--------|-----------------|
| Token pressure | 0–40 | How full the context is right now |
| Task completion | 0–20 | Whether Claude's last response signals the task is done |
| Relevance drift | 0–30 | How related the new prompt is to the current session (via Haiku) |
| Conversation age | 0–10 | How long since the last compact |

The total score drives the recommendation:

| Score | Action |
|-------|--------|
| 0–25 | Silent token bar only |
| 26–45 | Suggestion (💡) |
| 46–65 | Warning (⚠️) |
| 66–79 | Urgent (🚨) |
| 80+ | Block prompt until compacted (configurable) |

---

## Architecture

```
SessionStart
  └── session-init.sh
        Creates per-session state file, checks CLAUDE.md bloat,
        sets up statusline wrapper

Every prompt (UserPromptSubmit)
  └── check.sh (orchestrator)
        ├── analyze.js
        │     Reads JSONL transcript → exact token counts
        │     Calculates burn rate, turns left, cache efficiency, cost
        │
        ├── [if usage > 45%] advisor.js
        │     fingerprint.js → last 5 turns summary
        │     → Claude Haiku API (200 tokens, ~$0.0005)
        │     Scores: token_pressure + task_completion + drift + age
        │     Returns: score, action, recommendation text
        │
        └── stdout → injected into Claude's LLM context
            osascript/notify-send → desktop notification

After each response (Stop hook, background)
  └── update-state.sh
        Persists token history, burn rate, topics to state file
        Writes tmux status file (if enabled)

/compact lifecycle
  ├── pre-compact.sh (Smart Compact Instructions)
  │     Reads state file → builds dynamic instructions based on:
  │       1. Previous compact summary (carry-forward, prevents amnesia)
  │       2. Topic history (marks stale vs active topics)
  │       3. Active task state (completion status, relevance)
  │       4. Compact count (warns about cumulative loss risk)
  │     Falls back to static policy if no state available
  └── post-compact.sh
        Saves full compact summary to state for carry-forward
        Resets token history, logs compact event, sends notification

Status line (real-time, from Claude Code UI)
  └── statusline.sh
        Reads Claude Code's native context_window data
        Augments with plugin burn rate + turns left + cache efficiency
        Displays: 🟢 [████░░░] 22.1% · 44K/200K · ~124 turns · $0.012 · eff 74%
```

---

## Smart Compact Instructions

Claude Code's native compaction suffers from **cumulative amnesia** — each compact summarizes the previous summary, not the original conversation. After 2-3 compactions, key decisions and context are lost (see [anthropics/claude-code#33212](https://github.com/anthropics/claude-code/issues/33212)).

This plugin solves it by injecting **dynamic, context-aware instructions** into the compact prompt via the `PreCompact` hook. Instead of a static 4-line policy, the compact prompt now includes:

### What gets injected

**1. Previous compact summary (carry-forward)**

The full summary from the last compaction is preserved verbatim under a "Historical Context" section. This creates a cumulative memory chain — each compact carries forward all previous summaries, preventing exponential fidelity loss.

**2. Topic history (stale vs active)**

The advisor's topic drift detection is fed into the compact prompt. Stale topics (before the most recent topic shift) are marked for aggressive summarization. The active topic gets full detail preservation.

```
--- TOPIC HISTORY ---
Topic shifts detected during this session:
  [1] Turn 5: auth refactor
  [2] Turn 18: API rate limiting
  [3] Turn 34: deployment config
Active topic: deployment config (preserve in FULL detail)
Stale topics: auth refactor, API rate limiting
For stale topics: summarize AGGRESSIVELY — keep only final decisions and outcomes.
```

**3. Active task state**

The advisor's task completion detection and relevance score are injected:

- **COMPLETE**: Previous task finished — safe to compact its details aggressively
- **IN PROGRESS**: Task still running — preserve full debugging state and reasoning
- **UNRELATED topic shift**: Old context is stale — focus detail on the new topic

**4. Compact count warning**

After 3+ compactions, the prompt explicitly warns about cumulative context loss and instructs extra thoroughness in preserving key decisions and user-stated constraints.

### How it works

```
advisor.js (every prompt > 45%)
  └── Saves active_task to state file:
        { completion_status, topic_label, topic_relevance, compact_score }

post-compact.sh (after each compact)
  └── Saves full summary to state file:
        { last_compact_summary, last_compact_timestamp, last_compact_turn }

pre-compact.sh (before each compact)
  └── Reads state → builds dynamic instructions:
        Previous summary → "PRESERVE VERBATIM"
        Topic history    → "stale: summarize aggressively, active: full detail"
        Active task      → "COMPLETE: safe to drop" / "IN PROGRESS: keep all"
        Compact count   → "3+ compactions: be extra thorough"
```

---

## Installation

### Plugin system (recommended)

```bash
/plugin install fomyio/claude-context-monitor
```

Hooks register automatically. Start a new session — you'll see the token bar appear immediately.

### Manual

```bash
# Clone into your plugins directory
mkdir -p ~/.claude/plugins
git clone https://github.com/fomyio/claude-context-monitor.git ~/.claude/plugins/context-monitor

# Install dependencies
cd ~/.claude/plugins/context-monitor
npm install

# Register hooks — merge into ~/.claude/settings.json
# See hooks/settings-snippet.json for the exact block to add
```

### API key for Haiku evaluation

The plugin uses `ANTHROPIC_API_KEY` from your Claude Code session automatically.

If it's not in your environment:

```bash
echo "sk-ant-..." > ~/.anthropic_key
chmod 600 ~/.anthropic_key
```

---

## Configuration

All settings live in `config.json`. The defaults work well out of the box, but here's what you can tune:

```jsonc
{
  // Toggle the Haiku relevance evaluation (disable to save API calls)
  "relevance_eval_enabled": true,

  // Only run the eval above this usage percentage (saves cost at low usage)
  "relevance_eval_threshold_pct": 45,

  // Desktop notification thresholds (percentage)
  "notify_thresholds": {
    "info": 70,
    "warning": 85,
    "critical": 95
  },

  // Compact score thresholds
  "compact_score_thresholds": {
    "suggest": 26,   // 💡 soft suggestion
    "warn": 46,      // ⚠️  warning
    "urgent": 66,    // 🚨 urgent
    "block": 80      // 🛑 block the prompt (requires block_on_critical: true)
  },

  // Set to true to hard-block prompts when score >= block threshold
  "block_on_critical": false,

  // How many recent turns to include in the relevance fingerprint
  "fingerprint_max_turns": 5,

  // Warn if CLAUDE.md exceeds this % of the context limit
  "claude_md_bloat_threshold_pct": 15,

  // Enable the statusline integration
  "statusline_enabled": true,

  // Write context status to a file for tmux status bar (opt-in)
  "tmux_status_enabled": false,
  "tmux_status_file": "/tmp/claude-ctx-status"
}
```

---

## CLI dashboard

See a summary of your current session at any time:

```bash
context-monitor report
# or
node src/dashboard.js
```

Output:

```
Session: 34 turns | 47 min | claude-sonnet-4-6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Context:  [████████████████████░░░░░░░░░░░░░░░░░░░░]  51.3%  (103K / 200K)
Cost:     ~$0.041 this session  |  Cache eff: 74%
Burn:     ~8200 tokens/turn   |  ~12 turns remaining
Topics:   [auth refactor → API rate limiting]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Recommendation: ⚠️ Warning — Context threshold high. Consider /compact.
```

---

## Cost

The Haiku eval only activates above 45% context usage. At heavy use (1000 turns/month):

**~$0.50/month**

At normal use: closer to $0.05–0.15/month.

---

## Project structure

```
claude-context-monitor/
├── .claude-plugin/
│   ├── plugin.json          # Plugin manifest (name, version, author)
│   └── marketplace.json     # Marketplace manifest for /plugin install
├── config.json              # User-configurable thresholds + settings
├── package.json
├── hooks/
│   ├── hooks.json           # Hook registration definitions
│   ├── settings-snippet.json# Manual install: merge this into settings.json
│   ├── check.sh             # UserPromptSubmit — main orchestrator
│   ├── session-init.sh      # SessionStart — initialize session state
│   ├── update-state.sh      # Stop — persist stats after each response
│   ├── pre-compact.sh       # PreCompact — enrich compact instructions
│   └── post-compact.sh      # PostCompact — reset counter, log savings
├── src/
│   ├── analyze.js           # Token analyzer: reads JSONL transcript
│   ├── advisor.js           # Scoring engine: Haiku eval + compact score
│   ├── fingerprint.js       # Context summarizer: builds Haiku input
│   ├── statusline.sh        # Claude Code status line integration
│   ├── notify.sh            # Desktop notifications (macOS + Linux)
│   ├── dashboard.js         # CLI report
│   └── uninstall.sh         # Clean uninstall script
├── state/                   # Per-session JSON state files (auto-generated)
└── docs/
    └── PLAN.md              # Full implementation plan
```

---

## Contributing

Contributions are welcome. Here's how to work on this project.

### Getting started

```bash
git clone https://github.com/fomyio/claude-context-monitor.git
cd claude-context-monitor
npm install
```

### Branch naming

| Prefix | Purpose |
|--------|---------|
| `feature/` | New features |
| `fix/` | Bug fixes |
| `refactor/` | Code restructuring |
| `docs/` | Documentation |
| `chore/` | Maintenance, dependencies |

Always branch off `main`:

```bash
git checkout main
git pull origin main
git checkout -b feature/your-feature-name
```

### Before submitting a PR

- [ ] The plugin installs cleanly with `npm install`
- [ ] All hooks run without errors in a live Claude Code session
- [ ] `node src/analyze.js <transcript> <model> <session_id>` returns valid JSON
- [ ] No secrets, `.env` files, or API keys committed
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): description`
- [ ] Changes to hook behavior are documented in the PR description

### What's in scope

- **Hook improvements** — better token estimation, smarter scoring, new hook events
- **Platform support** — Windows notification support, new shell environments
- **Configuration** — new opt-in features that default to off
- **Dashboard** — richer `context-monitor report` output
- **Testing** — unit tests for `analyze.js` and `advisor.js`

### What's out of scope

- Breaking changes to `config.json` key names (existing users will lose settings)
- Requiring internet access for core functionality (Haiku eval is opt-in)
- Adding runtime dependencies that aren't in the Anthropic SDK

### Reporting issues

Please include:
1. Your OS and Claude Code version
2. The output of `node src/analyze.js` on a sample transcript (redact sensitive content)
3. Your `config.json` (redact API keys)
4. The exact hook output or error message

Open an issue at [github.com/fomyio/claude-context-monitor/issues](https://github.com/fomyio/claude-context-monitor/issues).

---

## License

MIT — see [LICENSE](LICENSE).

Built by [Mosaab](https://fomy.io).
