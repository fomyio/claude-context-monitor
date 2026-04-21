# Claude Context Monitor

**Real-time context window tracking with semantic compact scoring and cumulative amnesia prevention for Claude Code.**

[Install](#installation) · [Features](#features) · [How it works](#how-it-works) · [Configure](#configuration)

---

## What it does

Claude Code's 200,000-token context window fills up without warning. When it hits the limit, your session ends abruptly — often mid-refactor or mid-debug. This plugin watches your context in real time, predicts when you'll hit the wall, and tells you *before* it's too late. Then, when you run `/compact`, it makes sure Claude actually remembers what matters.

---

## Features

### Live context bar
Every prompt updates a real-time status line inside Claude's context:

```
[CTX] 🟢 [████░░░░░░░░░░░░░░░░] 22.1% | 44K/200K | ~124 turns left
```

Color shifts from 🟢 → 🟡 → 🔴 as usage grows. You always know where you stand.

### Smart compact recommendations
Above 45% usage, the plugin evaluates whether your current prompt is still related to the session topic. It sends a lightweight fingerprint to Claude Haiku (~200 tokens, ~$0.0005) and scores four signals: token pressure, task completion, relevance drift, and conversation age.

Recommendations escalate from gentle suggestions to urgent warnings:

| Score | Action |
|-------|--------|
| 26–45 | 💡 Suggestion |
| 46–65 | ⚠️ Warning |
| 66–79 | 🚨 Urgent |
| 80+ | 🛑 Block prompt (optional) |

### Cumulative amnesia fix
Claude Code's native `/compact` summarizes the previous summary, not the original conversation. After 2–3 compactions, key decisions and file paths vanish. This plugin solves it by injecting **Smart Compact Instructions** that:

- **Carry forward memory** — preserves the full previous compact summary verbatim in a "Historical Context" section
- **Mark stale vs active topics** — aggressively summarize finished tasks, preserve in-progress work in full detail
- **Signal task completion** — tells Claude whether it's safe to drop details or if work is ongoing
- **Warn on repeated compactions** — after 3+ compacts, explicitly flags cumulative quality degradation risk

### Desktop notifications
Alerts at 70%, 85%, and 95% usage via macOS or Linux native notifications — so you're never caught off guard.

### CLI dashboard
Run `context-monitor report` at any time to see a full session summary with burn rate, cost, topics, and recommendation.

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

## How it works

The plugin registers five Claude Code hooks:

| Hook | Purpose |
|------|---------|
| **SessionStart** | Initialize per-session state, check CLAUDE.md bloat, set up status line |
| **UserPromptSubmit** | Analyze tokens, run advisor scoring, inject status line into context |
| **Stop** | Persist token history, burn rate, and topics after each response (background) |
| **PreCompact** | Inject dynamic smart compact instructions before summarization |
| **PostCompact** | Save compact summary for carry-forward, reset state, notify |

All state is stored locally in per-session JSON files. The only external call is the optional Haiku relevance evaluation, which only fires above 45% usage.

---

## Installation

```bash
/plugin install fomyio/claude-context-monitor
```

Hooks register automatically. Start a new session — the token bar appears immediately.

### Manual install

```bash
mkdir -p ~/.claude/plugins
git clone https://github.com/fomyio/claude-context-monitor.git ~/.claude/plugins/context-monitor
cd ~/.claude/plugins/context-monitor && npm install
```

Then merge `hooks/settings-snippet.json` into `~/.claude/settings.json`.

### API key

The plugin inherits `ANTHROPIC_API_KEY` from your Claude Code session automatically. No extra configuration needed. To disable the Haiku evaluation entirely, set `"relevance_eval_enabled": false` in `config.json`.

---

## Configuration

All settings live in `config.json`. Key tunables:

```jsonc
{
  "relevance_eval_enabled": true,
  "relevance_eval_threshold_pct": 45,
  "notify_thresholds": { "info": 70, "warning": 85, "critical": 95 },
  "compact_score_thresholds": {
    "suggest": 26,
    "warn": 46,
    "urgent": 66,
    "block": 80
  },
  "block_on_critical": false,
  "statusline_enabled": true,
  "tmux_status_enabled": false
}
```

See `config.json` for the full reference including per-model context limits and pricing.

---

## Cost

The Haiku eval only activates above 45% context usage. At heavy use (1000 turns/month):

**~$0.50/month**

At normal use: closer to **$0.05–0.15/month**.

---

## Requirements

- Node.js >= 18
- macOS or Linux
- Claude Code

---

## Links

- [Repository](https://github.com/fomyio/claude-context-monitor)
- [Issues & feature requests](https://github.com/fomyio/claude-context-monitor/issues)
- [Full documentation](https://github.com/fomyio/claude-context-monitor/blob/main/README.md)

---

**License:** MIT · **Built by** [Mosaab](https://fomy.io)
