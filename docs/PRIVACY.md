# Privacy Policy

**Effective date:** 2026-04-21

**Plugin:** claude-context-monitor  
**Author:** Mosaab (https://fomy.io)  
**Repository:** https://github.com/fomyio/claude-context-monitor

---

## What data this plugin accesses

The plugin reads data that is already stored locally by Claude Code on your machine:

- **JSONL transcript files** — the session conversation log that Claude Code writes to disk. The plugin parses these to count tokens and compute context usage.
- **CLAUDE.md file** — checked at session start to warn if it exceeds a bloat threshold.
- **Local state files** — per-session JSON files the plugin itself creates under the `state/` directory.

The plugin does **not** access:
- Browser history, cookies, or bookmarks
- Files outside the Claude Code workspace
- System passwords, SSH keys, or credentials
- Network traffic unrelated to its own API call

---

## What data leaves your machine

### Optional Haiku relevance evaluation

Above 45% context usage, the plugin sends a **lightweight conversation fingerprint** (~200 tokens) to the Anthropic API (Claude Haiku) for relevance scoring. This happens only if:

- `"relevance_eval_enabled": true` in `config.json` (default: `true`)
- Context usage is above `"relevance_eval_threshold_pct"` (default: `45`)

The fingerprint contains:
- A summary of the last 5 conversation turns (role + truncated content)
- The current compact score and topic label

It does **not** contain:
- Raw file contents
- API keys or secrets
- Your Anthropic API key itself (the key is used for auth, not transmitted as content)

### No other external calls

All other functionality — token counting, state persistence, notifications, dashboard — is fully local. No telemetry, analytics, or logging services are used.

---

## How data is stored

- **State files:** Stored in `state/` as JSON files named by session ID. Deleted automatically when the session ends or the plugin is uninstalled.
- **No remote database:** No user data is stored on any server operated by the plugin author.
- **No tracking cookies:** None.

---

## Third parties

| Service | Purpose | Data sent |
|---------|---------|-----------|
| Anthropic API (Claude Haiku) | Relevance evaluation (~$0.0005/call) | Conversation fingerprint (~200 tokens) |

No other third parties receive data.

---

## Your choices

| Concern | Action |
|---------|--------|
| Disable Haiku eval entirely | Set `"relevance_eval_enabled": false` in `config.json` |
| Raise the eval threshold | Increase `"relevance_eval_threshold_pct"` in `config.json` |
| Delete local state | Remove the `state/` directory |
| Full uninstall | Run `/plugin uninstall context-monitor` or `bash src/uninstall.sh` |

---

## Contact

For privacy questions or to report a concern:

- Open an issue: https://github.com/fomyio/claude-context-monitor/issues
- Email: hello@fomy.io

---

## Changes to this policy

Updates will be posted to this file in the repository and summarized in the release notes. The effective date at the top of this document will be updated accordingly.
