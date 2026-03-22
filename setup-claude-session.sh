#!/usr/bin/env bash
# setup-claude-session.sh
#
# Adds a shell wrapper so every 'claude' invocation gets a unique
# x-litellm-session-id header. This enables session-based routing
# affinity in LiteLLM for better prompt caching.

set -euo pipefail

MARKER="# claude-session-affinity"
SHELL_RC="$HOME/.bashrc"

# Use .zshrc if running zsh
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
fi

if grep -qF "$MARKER" "$SHELL_RC" 2>/dev/null; then
    echo "Session affinity wrapper already installed in $SHELL_RC — skipping."
    exit 0
fi

cat >> "$SHELL_RC" << 'WRAPPER'

# claude-session-affinity
# Injects a unique session ID header per claude invocation for LiteLLM routing
claude-session() {
    ANTHROPIC_CUSTOM_HEADERS="x-litellm-session-id: $(uuidgen)" command claude "$@"
}
alias claude='claude-session'
WRAPPER

echo "Session affinity wrapper added to $SHELL_RC"
echo "Run 'source $SHELL_RC' or open a new terminal to activate."
