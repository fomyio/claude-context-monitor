<div align="center">

# 🧠 claude-context-monitor

### Stop losing work to silent context overflows.

A [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin that watches your context window in real time, predicts when you'll hit the limit, and warns you **before** it's too late — then makes your `/compact` actually remember what matters.

<br/>

[![Version](https://img.shields.io/badge/version-1.1.3-3b82f6?style=flat-square)](https://github.com/fomyio/claude-context-monitor/releases)
[![License: MIT](https://img.shields.io/github/license/fomyio/claude-context-monitor?style=flat-square&color=22c55e)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A5%2018-339933?style=flat-square&logo=node.js&logoColor=white)](https://nodejs.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-64748b?style=flat-square)](#requirements)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-d97757?style=flat-square)](https://docs.claude.com/en/docs/claude-code/plugins)

[![Stars](https://img.shields.io/github/stars/fomyio/claude-context-monitor?style=flat-square&color=eab308)](https://github.com/fomyio/claude-context-monitor/stargazers)
[![Issues](https://img.shields.io/github/issues/fomyio/claude-context-monitor?style=flat-square)](https://github.com/fomyio/claude-context-monitor/issues)
[![Last commit](https://img.shields.io/github/last-commit/fomyio/claude-context-monitor?style=flat-square&color=8b5cf6)](https://github.com/fomyio/claude-context-monitor/commits)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-ff69b4?style=flat-square)](#contributing)

<br/>

**[Quick start](#quick-start)** · **[Features](#features)** · **[How it works](#how-the-scoring-works)** · **[Configuration](#configuration)** · **[Cost & privacy](#cost)** · **[Contributing](#contributing)**

</div>

![ClaudeContextPlugin-ezgif com-optimize](https://github.com/user-attachments/assets/9666a5a8-bede-4493-8a36-34e92b6e1ad8)

---

<details>
<summary><b>📑 Table of contents</b></summary>

- [Why this exists](#why-this-exists)
- [Quick start](#quick-start)
- [Features](#features)
- [How the scoring works](#how-the-scoring-works)
- [Smart Compact Instructions](#smart-compact-instructions)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [CLI dashboard](#cli-dashboard)
- [Hooks](#hooks)
- [Cost](#cost)
- [Privacy](#privacy)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [Uninstalling](#uninstalling)
- [License](#license)

</details>

---

## Why this exists

Claude Code's context window fills up — and when it does, your session ends abruptly, mid-refactor or mid-debug. You get no warning. You just hit a wall.

Three problems, one plugin:

| Problem | What it feels like | How this plugin fixes it |
|---------|--------------------|--------------------------|
| **No warning** | The session dies with no heads-up | A live token bar + desktop alerts at 70 / 85 / 95% |
| **Bad timing** | Compact too early and waste a session; too late and lose context | A semantic score tells you *when* — and *why* |
| **Cumulative amnesia** | Each `/compact` summarizes the last summary, so after 2–3 rounds key decisions vanish | Carry-forward memory injected into the compact prompt |

> The amnesia problem is well documented — see [anthropics/claude-code#33212](https://github.com/anthropics/claude-code/issues/33212), [#28721](https://github.com/anthropics/claude-code/issues/28721), and [#3288](https://github.com/anthropics/claude-code/issues/3288).

---

## Quick start

```bash
# 1. Add this repo as a plugin marketplace
/plugin marketplace add fomyio/claude-context-monitor

# 2. Install the plugin
/plugin install context-monitor@claude-context-monitor

# 3. Reload, then start a new session — the token bar appears immediately
/reload-plugins
```

That's it — the five hooks register automatically. For the semantic compact scoring, the plugin uses your existing `ANTHROPIC_API_KEY` (see [API key](#api-key-for-the-haiku-evaluation)); everything else works with no key.

> **Tip:** prefer manual setup or want to disable the API eval entirely? See [Installation](#installation) and [SETUP.md](SETUP.md).

---

## Features

### 1. Real-time context monitoring

Every message, the plugin injects a status line into Claude's context:

```text
[CTX] 🟢 [████░░░░░░░░░░░░░░░░] 22.1% | 44K/200K | ~124 turns left
```

As the session grows, the color shifts 🟢 → 🟡 → 🔴 so you always know where you stand.

### 2. Smart compact recommendations

Above 45% usage, the plugin sends a lightweight fingerprint of your recent conversation to **Claude Haiku** (~$0.0005/call) and asks: *is this prompt a continuation, or a new topic?* It then scores the situation and escalates:

```text
[CTX] 💡 Suggestion: You might want to /compact (Topic drift detected)
[CTX] ⚠️  Warning: Good time to /compact soon (Score 47)
[CTX] 🚨 URGENT: Strongly recommend running /compact now (Score 71)
```

### 3. Smart Compact Instructions — *solves cumulative amnesia*

When you run `/compact`, the plugin doesn't just tell you *when* — it tells Claude *what to keep and what to drop*, and carries the previous summary forward verbatim. See [Smart Compact Instructions](#smart-compact-instructions).

### 4. Desktop notifications

Native alerts (macOS `osascript` / Linux `notify-send`) at **70%, 85%, and 95%** usage — so you're never caught off guard, even away from the terminal.

### 5. Status line integration

A real-time status bar in Claude Code's UI showing usage, turns left, cost, cache efficiency, and the active model:

```text
🟢 [████░░░░░░░░░░░░░░░░] 22.1% · 44K/200K · ~124 turns · $0.012 · eff 74% · Opus 4.8
```

The model label tracks the **live** model and updates the moment you switch models mid-session — the context-window size shown is always the limit for the model currently in use.

---

## How the scoring works

Every prompt is scored across four signals:

| Signal | Points | What it measures |
|--------|:------:|------------------|
| Token pressure | 0–40 | How full the context is right now |
| Task completion | 0–20 | Whether Claude's last response signals the task is done |
| Relevance drift | 0–30 | How related the new prompt is to the session (via Haiku) |
| Conversation age | 0–10 | How long since the last compact |

The total drives the recommendation (all thresholds configurable):

| Score | Action |
|:-----:|--------|
| 0–25 | 🟢 Silent token bar only |
| 26–45 | 💡 Suggestion |
| 46–65 | ⚠️ Warning |
| 66–79 | 🚨 Urgent |
| 80+ | 🛑 Block prompt until compacted *(opt-in via `block_on_critical`)* |

---

## Smart Compact Instructions

Claude Code's native compaction summarizes the *previous summary*, not the original conversation — so after a few rounds, key decisions and file paths are lost. This plugin injects **dynamic, context-aware instructions** into the compact prompt via the `PreCompact` hook.

<details>
<summary><b>1. Carry-forward memory (solves amnesia)</b></summary>

<br/>

The full summary from the *previous* compaction is preserved verbatim under a "Historical Context" section, creating a cumulative memory chain that prevents exponential fidelity loss.

```text
--- PREVIOUS COMPACT SUMMARY (PRESERVE VERBATIM) ---
This is a summary from a previous compaction in this session.
You MUST include this content in your new summary under a
"Historical Context" section. Do NOT discard or paraphrase it.

Session involved refactoring authentication module. Key decisions:
switched from JWT to session-based auth, updated middleware in auth.ts.
```

</details>

<details>
<summary><b>2. Topic-aware summarization (solves "what to keep")</b></summary>

<br/>

The advisor's Haiku-based drift detection marks which topics are **stale** (summarize aggressively) vs **active** (preserve in full detail).

```text
--- TOPIC HISTORY ---
Topic shifts detected during this session:
  [1] Turn 5: auth refactor
  [2] Turn 18: API rate limiting [drifted]
  [3] Turn 34: deployment config
Active topic: deployment config (preserve in FULL detail)
Stale topics: auth refactor, API rate limiting
For stale topics: summarize AGGRESSIVELY — keep only final decisions and outcomes.
```

</details>

<details>
<summary><b>3. Task completion signaling (solves "what to drop")</b></summary>

<br/>

The advisor detects whether your current task is complete, partial, or in progress:

- **COMPLETE** → "It is SAFE to compact this task's details aggressively. Preserve only final decisions."
- **IN PROGRESS** → "Do NOT compact away the active debugging state or work-in-progress."
- **UNRELATED topic shift** → "The user has started a new topic. Previous context is STALE. Summarize aggressively."

</details>

<details>
<summary><b>4. Compaction history warning</b></summary>

<br/>

After 3+ compactions, the prompt explicitly warns about cumulative quality degradation:

```text
--- COMPACTION HISTORY ---
This session has been compacted 3 time(s) before.
WARNING: Multiple compactions cause cumulative context loss.
Be EXTRA thorough in preserving key decisions, file paths, and
user-stated constraints. Include the Historical Context section.
```

</details>

All data flows through a per-session state file — no external services, no API calls beyond the existing Haiku eval.

---

## Architecture

<details>
<summary><b>Show the full data flow</b></summary>

<br/>

```text
SessionStart
  └── session-init.sh
        Creates per-session state file, checks CLAUDE.md bloat,
        sets up the statusline wrapper

Every prompt (UserPromptSubmit)
  └── check.sh (orchestrator)
        ├── analyze.js
        │     Reads the JSONL transcript → token counts
        │     Burn rate, turns left, cache efficiency, cost
        │     (prefers Claude Code's ground-truth context_window data)
        │
        ├── [if usage > 45%] advisor.js
        │     fingerprint.js → last 5 turns summary
        │     → Claude Haiku API (~$0.0005)
        │     Scores: token_pressure + task_completion + drift + age
        │     Persists: topic shifts, active_task to state
        │     Returns: score, action, recommendation text
        │
        └── stdout → injected into Claude's context
            osascript / notify-send → desktop notification

After each response (Stop hook, background)
  └── update-state.sh
        Persists token history, burn rate to state (atomic write)
        Writes tmux status file (if enabled)

/compact lifecycle
  ├── pre-compact.sh  → Smart Compact Instructions (carry-forward, topics, task, count)
  └── post-compact.sh → saves full summary for carry-forward, resets, notifies

Status line (real-time, from Claude Code UI)
  └── statusline.sh
        Reads Claude Code's native context_window data + live model
        Augments with burn rate, turns left, cache efficiency
        🟢 [████░░░] 22.1% · 44K/200K · ~124 turns · $0.012 · eff 74% · Opus 4.8
```

All writers read-fresh and write atomically (temp + rename), and pass every value to `node` via the environment — never interpolated into script source.

</details>

---

## Requirements

- **Node.js ≥ 18**
- **Claude Code**
- **macOS or Linux** (desktop notifications use `osascript` / `notify-send`; Windows is not yet supported)
- *(Optional)* an **`ANTHROPIC_API_KEY`** for the Haiku relevance evaluation

---

## Installation

### Plugin marketplace (recommended)

```bash
/plugin marketplace add fomyio/claude-context-monitor
/plugin install context-monitor@claude-context-monitor
/reload-plugins
```

<details>
<summary><b>Manual installation</b></summary>

<br/>

```bash
# Clone into your plugins directory
mkdir -p ~/.claude/plugins
git clone https://github.com/fomyio/claude-context-monitor.git ~/.claude/plugins/context-monitor

# Install dependencies
cd ~/.claude/plugins/context-monitor
npm install

# Register hooks — merge hooks/settings-snippet.json into ~/.claude/settings.json
```

</details>

### API key for the Haiku evaluation

The plugin uses `ANTHROPIC_API_KEY` from your Claude Code session automatically. If it's not in your environment:

```bash
echo "sk-ant-..." > ~/.anthropic_key
chmod 600 ~/.anthropic_key
```

The token bar, notifications, and status line work **without** a key — only the topic-drift scoring needs one. See [SETUP.md](SETUP.md) for alternatives (custom key command, or disabling the eval entirely).

---

## Configuration

All settings live in `config.json`. The defaults work well out of the box.

<details>
<summary><b>Show all configuration options</b></summary>

<br/>

```jsonc
{
  // Toggle the Haiku relevance evaluation (disable to save API calls)
  "relevance_eval_enabled": true,

  // Only run the eval above this usage percentage (saves cost at low usage)
  "relevance_eval_threshold_pct": 45,

  // Shell command that prints your API key (fallback when ANTHROPIC_API_KEY is unset)
  "anthropic_api_key_cmd": "cat ~/.anthropic_key",

  // Desktop notification thresholds (percentage)
  "notify_thresholds": { "info": 70, "warning": 85, "critical": 95 },

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

  // Number of recent turns used for burn-rate calculation
  "burn_rate_window_turns": 4,

  // Warn if CLAUDE.md exceeds this % of the context limit
  "claude_md_bloat_threshold_pct": 15,

  // Status line integration
  "statusline_enabled": true,

  // Write context status to a file for a tmux status bar (opt-in)
  "tmux_status_enabled": false,
  "tmux_status_file": "/tmp/claude-ctx-status",

  // Where per-session state is stored
  "state_dir": "~/.claude/plugins/context-monitor/state",

  // Per-model context limits (tokens). Claude Code's live value overrides these.
  "context_limits": {
    "claude-opus-4-7": 200000,
    "claude-opus-4-6": 200000,
    "claude-opus-4-5": 200000,
    "claude-opus-4": 200000,
    "claude-sonnet-4-6": 200000,
    "claude-sonnet-4-5": 200000,
    "claude-haiku-4-5": 200000
  },

  // Per-model pricing (USD per million input tokens)
  "model_prices_per_million_input": {
    "claude-opus-4-7": 15.00,
    "claude-opus-4-6": 15.00,
    "claude-opus-4-5": 15.00,
    "claude-opus-4": 15.00,
    "claude-sonnet-4-6": 3.00,
    "claude-sonnet-4-5": 3.00,
    "claude-haiku-4-5": 0.80
  }
}
```

> The static `context_limits` table is only a fallback — when Claude Code reports a live `limit_tokens` (e.g. a 1M-token model), the plugin uses that instead, so the bar always reflects the model actually in use.

</details>

---

## CLI dashboard

See a summary of your current session at any time:

```bash
context-monitor report   # or: node src/dashboard.js
```

```text
Session: 34 turns | 47 min | Sonnet 4.6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Context:  [████████████████████░░░░░░░░░░░░░░░░░░░░]  51.3%  (103K / 200K)
Cost:     ~$0.041 this session  |  Cache eff: 74%
Burn:     ~8200 tokens/turn   |  ~12 turns remaining
Topics:   [auth refactor → API rate limiting]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Recommendation: ⚠️ Warning — Context threshold high. Consider /compact.
```

---

## Hooks

The plugin registers five Claude Code hooks (`hooks/hooks.json`):

| Hook | Script | Purpose |
|------|--------|---------|
| `SessionStart` | `hooks/session-init.sh` | Initialize per-session state, check CLAUDE.md bloat, set up statusline |
| `UserPromptSubmit` | `hooks/check.sh` | Run token analysis + advisor scoring, inject the status line |
| `Stop` | `hooks/update-state.sh` | Persist token history and stats after each response *(background)* |
| `PreCompact` | `hooks/pre-compact.sh` | Inject Smart Compact Instructions before summarization |
| `PostCompact` | `hooks/post-compact.sh` | Save the compact summary for carry-forward, reset state, notify |

---

## Cost

The Haiku eval only activates **above 45%** context usage.

| Usage pattern | Estimated monthly cost |
|---------------|:----------------------:|
| Normal use | **~$0.05 – $0.15** |
| Heavy use (≈1000 turns/mo) | **~$0.50** |

Each eval is a single ~60-token Haiku call. With the eval disabled (`relevance_eval_enabled: false`), the plugin costs **$0** to run.

---

## Privacy

The plugin runs entirely on your machine. The **only** outbound network call is the optional Haiku relevance eval, which sends a short fingerprint of your recent turns to the Anthropic API — and only above 45% usage, only if enabled. No telemetry, no third-party services. Full details in **[PRIVACY.md](PRIVACY.md)**.

---

## Project structure

<details>
<summary><b>Show the file tree</b></summary>

<br/>

```text
claude-context-monitor/
├── .claude-plugin/
│   ├── plugin.json           # Plugin manifest (name, version, author)
│   └── marketplace.json      # Marketplace manifest for /plugin install
├── hooks/
│   ├── hooks.json            # Hook registrations (${CLAUDE_PLUGIN_ROOT} paths)
│   ├── settings-snippet.json # Manual install: merge into settings.json
│   ├── session-init.sh       # SessionStart — initialize session state
│   ├── check.sh              # UserPromptSubmit — main orchestrator
│   ├── update-state.sh       # Stop — persist stats after each response
│   ├── pre-compact.sh        # PreCompact — smart compact instructions
│   └── post-compact.sh       # PostCompact — save summary, reset state
├── src/
│   ├── analyze.js            # Token analyzer: reads the JSONL transcript
│   ├── advisor.js            # Scoring engine: Haiku eval + compact score
│   ├── fingerprint.js        # Context summarizer: builds the Haiku input
│   ├── statusline.sh         # Claude Code status line integration
│   ├── notify.sh             # Desktop notifications (macOS + Linux)
│   ├── dashboard.js          # CLI report (bin: context-monitor)
│   └── uninstall.sh          # Clean uninstall script
├── docs/
│   ├── HOMEPAGE.md           # Plugin homepage
│   ├── PLAN.md               # Implementation plan / roadmap
│   ├── PRIVACY.md            # Privacy details
│   └── MARKETPLACE_SUBMISSION.md
├── config.json               # User-configurable thresholds + settings
├── SETUP.md                  # API key setup guide
├── PRIVACY.md                # Privacy policy
├── LICENSE                   # MIT
└── package.json
```

Per-session state lives outside the repo, under `~/.claude/plugins/context-monitor/state/` (configurable via `state_dir`).

</details>

---

## Contributing

Contributions are welcome!

<details>
<summary><b>Getting started, branch naming, and PR checklist</b></summary>

<br/>

```bash
git clone https://github.com/fomyio/claude-context-monitor.git
cd claude-context-monitor
npm install
```

**Branch naming**

| Prefix | Purpose |
|--------|---------|
| `feature/` | New features |
| `fix/` | Bug fixes |
| `refactor/` | Code restructuring |
| `docs/` | Documentation |
| `chore/` | Maintenance, dependencies |

Always branch off `main`:

```bash
git checkout main && git pull origin main
git checkout -b feature/your-feature-name
```

**Before submitting a PR**

- [ ] `npm install` succeeds
- [ ] `node --check src/*.js` and `bash -n hooks/*.sh src/*.sh` pass
- [ ] All hooks run without errors in a live Claude Code session
- [ ] `node src/analyze.js <transcript> <model> <session_id>` returns valid JSON
- [ ] No secrets, `.env` files, or API keys committed
- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): description`

**In scope:** hook improvements, platform support (e.g. Windows notifications), opt-in config features, richer dashboard output, tests for `analyze.js` / `advisor.js`.

**Out of scope:** breaking `config.json` key renames, requiring internet for core functionality, runtime deps beyond the Anthropic SDK.

**Reporting issues** — include your OS + Claude Code version, sample `analyze.js` output (redacted), your `config.json` (redact keys), and the exact hook output. Open an issue [here](https://github.com/fomyio/claude-context-monitor/issues).

</details>

---

## Uninstalling

```bash
/plugin uninstall context-monitor@claude-context-monitor
```

Or manually:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/src/uninstall.sh
```

This removes the statusline entry from `settings.json`, cleans up the statusline wrapper, and removes orphaned cache directories.

---

## License

[MIT](LICENSE) — built by [Mosaab](https://fomy.io).

<div align="center">
<br/>
<sub>If this plugin saved you from a lost session, consider giving it a ⭐ — it helps others find it.</sub>
</div>
