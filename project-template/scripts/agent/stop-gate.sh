#!/usr/bin/env bash
# Claude Code Stop / SubagentStop hook: an agent may not finish while its
# branch fails `just check`. Conversations without code changes stop normally.
# Exit 2 sends the failure back to the agent, which keeps working.
# shellcheck disable=SC2016 # backticks in the message are Markdown, not commands
set -uo pipefail

input=$(cat)
# Already continued once because of this hook: let it stop (no endless loops).
[[ $(jq -r '.stop_hook_active // false' <<<"$input") == true ]] && exit 0
command -v just >/dev/null || exit 0

dir=$(jq -r '.cwd // empty' <<<"$input")
cd "${dir:-$PWD}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
branch=$(git branch --show-current)
[[ -n $branch && $branch != main ]] || exit 0

# Nothing to check without changes (new files included) or commits beyond main.
if [[ -z $(git status --porcelain 2>/dev/null) && -z $(git log --oneline origin/main..HEAD 2>/dev/null) ]]; then
  exit 0
fi

if out=$(just check 2>&1); then
  exit 0
fi
printf '`just check` fails on branch %s. Fix it before finishing; never disable tests or lints.\n\n%s\n' \
  "$branch" "$(tail -n 40 <<<"$out")" >&2
exit 2
