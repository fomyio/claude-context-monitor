#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact hook
# Outputs plain-text instructions to stdout, which Claude Code injects into
# the compact prompt as context (systemMessage is a UI warning, not Claude context).

set -euo pipefail

cat << 'EOF'
Context Monitor Policy: When summarizing this session, please explicitly preserve:
1. All absolute and relative file paths that have been modified or discussed.
2. Any specific error messages we are currently trying to fix.
3. Important environment variables, config values, or port numbers.
4. Output these as a structured list at the top or bottom of your summary.
EOF

exit 0
