# Marketplace Submission — Claude Context Monitor

> Ready-to-copy fields for the Claude Code Plugin Marketplace.

---

## Plugin Links

| Field | Value |
|-------|-------|
| **Link to plugin** | `https://github.com/fomyio/claude-context-monitor` |
| **Plugin homepage** | `https://github.com/fomyio/claude-context-monitor/blob/main/docs/HOMEPAGE.md` |

---

## Plugin Details

### Plugin name

`claude-context-monitor`

### Plugin description

Prevent context window exhaustion. Real-time token tracking, semantic compact scoring, and carry-forward memory that fixes cumulative amnesia across `/compact` cycles.

**What it does:**

Claude Code's 200,000-token context window fills up without warning. When it hits the limit, your session ends abruptly — often mid-refactor or mid-debug. This plugin watches your context in real time, predicts when you'll hit the wall, and tells you *before* it's too late. Then, when you run `/compact`, it makes sure Claude actually remembers what matters.

**Key features:**

- **Live context bar** — Real-time usage %, tokens consumed, turns remaining, cost, and cache efficiency injected into every prompt. Color shifts from green → yellow → red as you approach the limit.
- **Smart compact recommendations** — Above 45% usage, evaluates topic relevance via Claude Haiku (~200 tokens, ~$0.0005). Scores token pressure, task completion, relevance drift, and conversation age. Escalates from gentle suggestions to urgent warnings.
- **Cumulative amnesia fix** — Injects Smart Compact Instructions that carry forward the full previous summary verbatim, mark stale vs active topics, signal task completion, and warn on repeated compactions.
- **Desktop notifications** — Alerts at 70%, 85%, and 95% usage via macOS or Linux native notifications.
- **CLI dashboard** — Run `context-monitor report` for a full session summary with burn rate, cost, topics, and recommendation.

**Cost:** ~$0.05–0.50/month. The Haiku eval only fires above 45% usage.

**Requirements:** Node.js >= 18, macOS or Linux, Claude Code.

---

### Example use cases

**Example 1: Long refactoring session**
You're 40 turns into a large refactor across multiple files. The plugin shows `[CTX] 🟡 [████████████░░░░░░░░] 62.3% | 125K/200K | ~18 turns left`. The advisor detects the task is still in progress and warns you to `/compact` soon. When you compact, the Smart Compact Instructions preserve all file paths, key decisions, and the full previous summary so you don't lose track of what changed.

**Example 2: Topic drift during a support session**
You start debugging an auth issue, then switch to API rate limiting, then deployment config. The plugin detects the topic shifts and scores relevance drift lower each time. At 55% usage, it suggests: `[CTX] 💡 Suggestion: You might want to /compact (Topic drift detected)`. When you compact, stale topics (auth refactor, rate limiting) are marked for aggressive summarization while the active topic (deployment config) is preserved in full detail.

**Example 3: Preventing cumulative amnesia across compactions**
You've compacted twice already in this session. Key decisions about middleware changes and file renames are at risk of vanishing. The plugin's PreCompact hook injects the full previous summary as a "Historical Context" section, explicitly warns that 2 compactions have already occurred, and instructs Claude to preserve key decisions and file paths with extra care.

**Example 4: Cost-conscious monitoring**
You want to keep an eye on session cost without staring at the terminal. The plugin's status line shows `$0.012` and cache efficiency `74%` on every turn. Desktop notifications fire at 70%, 85%, and 95% so you can step away and still know when to compact.

---

## Ready-to-paste JSON

> **Note:** Add `"version"` manually — see `package.json` for the current value to avoid drift.

```json
{
  "name": "context-monitor",
  "description": "Prevent context window exhaustion. Real-time token tracking, semantic compact scoring, and carry-forward memory that fixes cumulative amnesia across /compact cycles.",
  "author": {
    "name": "Mosaab",
    "url": "https://fomy.io"
  },
  "homepage": "https://github.com/fomyio/claude-context-monitor/blob/main/docs/HOMEPAGE.md",
  "repository": "https://github.com/fomyio/claude-context-monitor.git",
  "keywords": [
    "context-window",
    "context-monitor",
    "token-tracker",
    "compact",
    "statusline",
    "hooks",
    "context-usage",
    "token-budget"
  ]
}
```
