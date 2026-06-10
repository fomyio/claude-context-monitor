#!/usr/bin/env bash
# hooks/session-init.sh — SessionStart hook
# Reads SessionStart JSON from stdin, creates per-session state file
# and checks CLAUDE.md bloat.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
CONFIG="$PLUGIN_DIR/config.json"

# Claude Code's active config dir — honors CLAUDE_CONFIG_DIR (multi-account /
# custom homes). The statusline wrapper + settings.json registration must land
# here, not a hardcoded ~/.claude, or the status bar silently never appears for
# anyone running a non-default config dir.
CLAUDE_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Every step relies on node; bail cleanly if it is missing so an unguarded
# `node ... ` write can't abort the script under `set -e`.
command -v node >/dev/null 2>&1 || exit 0

# ── Helper: read config value ─────────────────────────────────────────────────
config_get() {
  node -e "
    const c = JSON.parse(require('fs').readFileSync('$CONFIG', 'utf8'));
    const keys = '$1'.split('.');
    let v = c;
    for (const k of keys) v = v?.[k];
    console.log(v ?? '$2');
  " 2>/dev/null || echo "$2"
}

# ── Read hook input ───────────────────────────────────────────────────────────
INPUT="$(cat)"
SESSION_ID="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.session_id ?? d.sessionId ?? '');" 2>/dev/null || echo '')"
MODEL="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.model ?? '');" 2>/dev/null || echo '')"
TRANSCRIPT_PATH="$(echo "$INPUT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d.transcript_path ?? d.transcriptPath ?? '');" 2>/dev/null || echo '')"

if [ -z "$SESSION_ID" ]; then
  # Cannot initialize without session id — exit silently
  exit 0
fi

# ── Resolve state dir ─────────────────────────────────────────────────────────
STATE_DIR_CFG="$(config_get state_dir "$HOME/.claude/plugins/context-monitor/state")"
STATE_DIR="${STATE_DIR_CFG/#\~/$HOME}"
mkdir -p "$STATE_DIR"

STATE_FILE="$STATE_DIR/$SESSION_ID.json"

# ── Create initial state file ─────────────────────────────────────────────────
# Values are passed via the environment (never interpolated into JS source) so a
# session id, model, or transcript path containing quotes/backticks/${} cannot
# break the write or execute code. Written atomically (temp + rename).
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SESSION_ID="$SESSION_ID" MODEL="$MODEL" STARTED_AT="$STARTED_AT" \
TRANSCRIPT_PATH="$TRANSCRIPT_PATH" STATE_FILE="$STATE_FILE" node -e '
const fs = require("fs");
const stateFile = process.env.STATE_FILE;
const state = {
  session_id: process.env.SESSION_ID,
  model: process.env.MODEL || "",
  started_at: process.env.STARTED_AT,
  transcript_path: process.env.TRANSCRIPT_PATH || "",
  token_history: [],
  topics: [],
  last_compact_at_turn: 0,
  total_turns: 0,
  last_assistant_message: "",
  claude_md_tokens: 0,
  compact_events: [],
  last_compact_summary: "",
  last_compact_timestamp: null,
  last_compact_turn: null,
  active_task: null
};
const tmp = stateFile + ".tmp." + process.pid;
fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
fs.renameSync(tmp, stateFile);
' 2>/dev/null || true

# ── CLAUDE.md bloat check ─────────────────────────────────────────────────────
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
# Also check local CLAUDE.md
LOCAL_CLAUDE_MD="$(pwd)/CLAUDE.md"

BLOAT_THRESHOLD="$(config_get claude_md_bloat_threshold_pct 15)"

check_claude_md_bloat() {
  local md_path="$1"
  local label="$2"
  if [ ! -f "$md_path" ]; then return; fi

  local size_bytes
  size_bytes="$(wc -c < "$md_path" | tr -d ' ')"
  local model_limit
  model_limit="$(MODEL="$MODEL" CONFIG="$CONFIG" PLUGIN_DIR="$PLUGIN_DIR" node -e '
    const { lookupLimit } = require(process.env.PLUGIN_DIR + "/src/context-limit.js");
    const c = JSON.parse(require("fs").readFileSync(process.env.CONFIG, "utf8"));
    console.log(lookupLimit(process.env.MODEL || "", c.context_limits || {}));
  ' 2>/dev/null || echo 200000)"

  # Estimate tokens: chars / 3.5
  local est_tokens
  est_tokens=$(( size_bytes * 10 / 35 ))
  local threshold_tokens
  threshold_tokens=$(( model_limit * BLOAT_THRESHOLD / 100 ))

  if [ "$est_tokens" -gt "$threshold_tokens" ]; then
    echo "[CTX] ⚠️  $label is large (~${est_tokens} tokens = $(( est_tokens * 100 / model_limit ))% of context). Consider trimming it."
  fi

  # Persist to state (env + atomic write, consistent with the rest of the hooks)
  EST_TOKENS="$est_tokens" STATE_FILE="$STATE_FILE" node -e '
    const fs = require("fs");
    const stateFile = process.env.STATE_FILE;
    const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    state.claude_md_tokens = parseInt(process.env.EST_TOKENS, 10) || 0;
    const tmp = stateFile + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
    fs.renameSync(tmp, stateFile);
  ' 2>/dev/null || true
}

check_claude_md_bloat "$CLAUDE_MD" "~/.claude/CLAUDE.md"
check_claude_md_bloat "$LOCAL_CLAUDE_MD" "CLAUDE.md"

# ── Statusline wrapper setup ──────────────────────────────────────────────────
# Writes <config-dir>/statusline.sh as a self-cleaning wrapper each session.
# On upgrade: wrapper is rewritten with the current plugin path.
# On uninstall: next statusLine call detects missing plugin, removes the
#               statusLine entry from settings.json, and deletes itself.
setup_statusline() {
  local wrapper_path="$CLAUDE_CFG_DIR/statusline.sh"
  local plugin_script="$PLUGIN_DIR/src/statusline.sh"
  local settings_file="$CLAUDE_CFG_DIR/settings.json"

  # Only write wrapper if absent or previously generated by this plugin
  if [ ! -f "$wrapper_path" ] || head -n 2 "$wrapper_path" | grep -q "Auto-generated by claude-context-monitor"; then
    cat > "$wrapper_path" << EOF
#!/usr/bin/env bash
# Auto-generated by claude-context-monitor plugin — do not edit manually.
# Regenerated each session; safe to delete (plugin will recreate it).
PLUGIN_SCRIPT="$plugin_script"
PLUGIN_DIR="$PLUGIN_DIR"
SETTINGS_FILE="$settings_file"
WRAPPER_PATH="$wrapper_path"
if [ -f "\$PLUGIN_SCRIPT" ] && [ ! -f "\$PLUGIN_DIR/.orphaned_at" ]; then
  exec bash "\$PLUGIN_SCRIPT"
else
  # Plugin removed or orphaned — clean up and self-destruct.
  # Exit 0 → rm runs (our statusLine removed, or it belongs to another tool — wrapper is dead weight either way).
  # Exit 1 (write error) → rm is skipped so the stale entry isn't left pointing to a deleted file.
  SETTINGS_FILE="\$SETTINGS_FILE" WRAPPER_PATH="\$WRAPPER_PATH" node -e 'const fs=require("fs"),f=process.env.SETTINGS_FILE,w=process.env.WRAPPER_PATH;try{const s=JSON.parse(fs.readFileSync(f,"utf8"));if(s.statusLine&&s.statusLine.command===w){delete s.statusLine;fs.writeFileSync(f,JSON.stringify(s,null,2));}process.exit(0);}catch(_){process.exit(1);}' 2>/dev/null && rm -f "\$0"
fi
EOF
    chmod +x "$wrapper_path"
  fi

  # Ensure settings.json has the statusLine entry, pointing at the absolute
  # wrapper path in the active config dir (a bare '~/.claude/...' would not
  # resolve to a custom CLAUDE_CONFIG_DIR). Also MIGRATE an existing entry we
  # own — including the legacy '~/.claude/statusline.sh' tilde path — to the
  # absolute path, so the wrapper's self-clean snippet (which matches the
  # absolute path) keeps working for upgraded installs. A statusLine pointing
  # anywhere else belongs to another tool and is left untouched.
  SETTINGS_FILE="$settings_file" WRAPPER_PATH="$wrapper_path" node -e "
    const fs = require('fs');
    const f = process.env.SETTINGS_FILE;
    const wrapper = process.env.WRAPPER_PATH;
    let s = {};
    try {
      s = JSON.parse(fs.readFileSync(f, 'utf8'));
    } catch(e) {
      if (e.code !== 'ENOENT') process.exit(0); // malformed JSON — skip to avoid clobbering settings
    }
    const cur = s.statusLine && s.statusLine.command;
    const ours = [wrapper, '~/.claude/statusline.sh'];
    if (!s.statusLine || ours.includes(cur)) {
      if (cur !== wrapper) { // skip the no-op write when already correct
        s.statusLine = { type: 'command', command: wrapper };
        fs.writeFileSync(f, JSON.stringify(s, null, 2));
      }
    }
  " 2>/dev/null || true
}

STATUSLINE_ENABLED="$(config_get statusline_enabled true)"
if [ "$STATUSLINE_ENABLED" = "true" ]; then
  setup_statusline
fi

exit 0
