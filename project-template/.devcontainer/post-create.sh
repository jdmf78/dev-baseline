#!/usr/bin/env bash
# Runs once when the devcontainer (or a Codespace) is created: same tools as the server.
# AI coding CLIs: all three, or set AGENTS (e.g. "claude codex") under
# containerEnv in devcontainer.json.
set -euo pipefail

agents=${AGENTS:-claude codex opencode}
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
curl -fsSL https://mise.run | sh
mise trust --quiet
mise install
mise use --global --yes bun@latest
for agent in $agents; do
  case $agent in
    claude)   curl -fsSL https://claude.ai/install.sh | bash ;;
    codex)    mise use --global --yes npm:@openai/codex@latest ;;
    opencode) mise use --global --yes npm:@opencode/cli@latest ;;
    *)        echo "Unknown agent in AGENTS: $agent" >&2; exit 1 ;;
  esac
done

# The team: GSD Core and gstack, as on the server (machine/bootstrap.sh).
gs="$HOME/.claude/skills/gstack"
[[ -d $gs ]] || git clone -q --single-branch --depth 1 https://github.com/garrytan/gstack.git "$gs"
for agent in $agents; do
  npx -y @opengsd/gsd-core@latest "--$agent" --global </dev/null || echo "GSD Core for $agent failed" >&2
  (cd "$gs" && ./setup --host "$agent" </dev/null) || echo "gstack for $agent failed" >&2
done

# shellcheck disable=SC2016 # written literally, expanded by each new shell
grep -q 'mise activate' ~/.bashrc || echo 'eval "$(mise activate bash)"' >>~/.bashrc
just hooks
