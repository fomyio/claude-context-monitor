# 🧠 claude-context-monitor

> A Claude Code plugin that tracks context window usage in real-time, evaluates semantic relevance of new prompts using Claude Haiku, and proactively suggests the optimal time to compact or clear — before you hit limits.

## What It Does

Claude Code gives you no proactive signal about context limits. This plugin adds:

- **Real-time token tracking** — reads the session JSONL log after every turn to estimate exact usage
- **Burn rate prediction** — tells you how many turns you have left before hitting the limit
- **Semantic relevance evaluation** — uses `claude-haiku-4-5` to detect when your new prompt is unrelated to the current context (the ideal compact moment)
- **Smart compact scoring** — combines token pressure, topic drift, task completion signals, and conversation age into one actionable score
- **Proactive injections** — injects a status bar + recommendation directly into Claude's context so Claude itself becomes aware of its pressure
- **Desktop notifications** — macOS/Linux alerts at 70%, 85%, 95% thresholds

## How It Works

```
UserPromptSubmit hook fires
        │
        ▼
   analyze.js reads JSONL
   → estimates input + output tokens
   → computes burn rate & turns left
        │
        ▼ (if > 45% usage)
   advisor.js builds context fingerprint
   → calls claude-haiku-4-5 (~200 tokens)
   → receives: { score, label, reason }
        │
        ▼
   Compact Score = token_pressure
                 + relevance_drift
                 + task_completion
                 + conversation_age
        │
   Score 0–25: silent token bar
   Score 26–65: suggestion notification
   Score 66–80: urgent warning
   Score 80+:  block prompt (exit 2)
        │
        ▼
   stdout → injected into Claude's LLM context
   osascript → macOS desktop notification
```

## Installation

### Via Claude Code CLI (Recommended)

```bash
# 1. Add the marketplace and install the plugin
/plugin marketplace add fomyio/claude-context-monitor
/plugin install context-monitor@claude-context-monitor

# 2. That's it! Hooks are registered automatically.
#    Start a new session and you'll see the token bar appear.
```

### Manual Installation

```bash
# 1. Clone into Claude plugins directory
mkdir -p ~/.claude/plugins
cp -r . ~/.claude/plugins/context-monitor

# 2. Install dependencies
cd ~/.claude/plugins/context-monitor
npm install

# 3. Register hooks — merge hooks/hooks.json into ~/.claude/settings.json

# 4. Test
claude  # Start a Claude Code session — you'll see the token bar appear
```

### API Key (for Haiku Relevance Eval)

The plugin automatically uses the `ANTHROPIC_API_KEY` environment variable from your Claude Code session.
If that's not available, it falls back to reading `~/.anthropic_key`:

```bash
echo "sk-ant-..." > ~/.anthropic_key
chmod 600 ~/.anthropic_key
```

## Configuration

Edit `config.json` to customize thresholds, toggle the haiku eval, and set alert levels.

## Project Structure

```
claude-context-monitor/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest (name, version, author)
│   └── marketplace.json         # Marketplace manifest for CLI install
├── README.md
├── package.json
├── config.json                  # User-configurable thresholds + settings
├── hooks/
│   ├── hooks.json               # Hook registration for plugin system
│   ├── check.sh                 # UserPromptSubmit — main orchestrator
│   ├── session-init.sh          # SessionStart — initialize session state
│   ├── update-state.sh          # Stop — persist stats after response
│   ├── pre-compact.sh           # PreCompact — inject enriched compact instructions
│   └── post-compact.sh          # PostCompact — reset counter, log savings
├── src/
│   ├── analyze.js               # Token analyzer: JSONL → usage stats
│   ├── advisor.js               # Intelligence engine: relevance eval + compact score
│   ├── fingerprint.js           # Context summarizer for haiku input
│   ├── notify.sh                # Desktop notification dispatcher
│   └── dashboard.js             # CLI dashboard: context-monitor report
├── state/                       # Per-session state files (auto-generated)
└── docs/
    └── PLAN.md                  # Full implementation plan
```

## Cost

The haiku relevance eval costs ~$0.0005 per turn and only activates above 45% context usage.
At 1000 turns/month of heavy use: **~$0.50/month**.
