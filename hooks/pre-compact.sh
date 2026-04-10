#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact hook
# Injects custom instructions for the compact operation to ensure critical
# context (like file paths and strict constraints) isn't lost during summarization.

set -euo pipefail

# Print the JSON object Claude Code expects from standard hook execution
# The hookSpecificOutput key is merged into the event lifecycle explicitly
cat << 'EOF'
{
  "systemMessage": "Context Monitor Policy: When summarizing this session, please explicitly preserve:\n1. All absolute and relative file paths that have been modified or discussed.\n2. Any specific error messages we are currently trying to fix.\n3. Important environment variables, config values, or port numbers.\n4. Output these as a structured list at the top or bottom of your summary."
}
EOF

exit 0
