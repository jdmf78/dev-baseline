#!/usr/bin/env bash
# Runs once when the devcontainer (or a Codespace) is created: same tools as the server.
set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
curl -fsSL https://mise.run | sh
mise trust --quiet
mise install
mise use --global --yes npm:@openai/codex@latest
curl -fsSL https://claude.ai/install.sh | bash
# shellcheck disable=SC2016 # written literally, expanded by each new shell
grep -q 'mise activate' ~/.bashrc || echo 'eval "$(mise activate bash)"' >>~/.bashrc
just hooks
