#!/usr/bin/env bash
# Runs once when the devcontainer (or a Codespace) is created: same tools as the server.
set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
curl -fsSL https://mise.run | sh
mise trust --quiet
mise install
mise use --global --yes npm:@openai/codex@latest bun@latest
curl -fsSL https://claude.ai/install.sh | bash

# The team: GSD Core and gstack, as on the server (machine/bootstrap.sh).
npx -y @opengsd/gsd-core@latest --claude --global </dev/null || echo "GSD Core for Claude Code failed" >&2
npx -y @opengsd/gsd-core@latest --codex --global </dev/null || echo "GSD Core for Codex failed" >&2
gs="$HOME/.claude/skills/gstack"
[[ -d $gs ]] || git clone -q --single-branch --depth 1 https://github.com/garrytan/gstack.git "$gs"
(cd "$gs" && ./setup </dev/null) || echo "gstack setup failed" >&2

# shellcheck disable=SC2016 # written literally, expanded by each new shell
grep -q 'mise activate' ~/.bashrc || echo 'eval "$(mise activate bash)"' >>~/.bashrc
just hooks
