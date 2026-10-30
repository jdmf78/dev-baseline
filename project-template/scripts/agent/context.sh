#!/usr/bin/env bash
# Claude Code SessionStart hook: brief every session on the goal and the
# team's open work. Whatever this prints becomes context. Never fails.
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
limit() { if command -v timeout >/dev/null; then timeout 10 "$@"; else "$@"; fi; }

if [[ -f docs/GOAL.md ]]; then
  echo "Current goal (docs/GOAL.md): $(grep -m1 '^# ' docs/GOAL.md | sed 's/^# *//')"
fi
if command -v gh >/dev/null; then
  limit gh issue list --label agent --state open --limit 30 --json number,title,labels --jq \
    'if length > 0 then "Open team issues:", (.[] | "  #\(.number) \(.title) [\([.labels[].name] | join(", "))]") else empty end' 2>/dev/null
  limit gh pr list --label agent --state open --limit 30 --json number,title,labels --jq \
    'if length > 0 then "Open team PRs:", (.[] | "  #\(.number) \(.title) [\([.labels[].name] | join(", "))]") else empty end' 2>/dev/null
fi
echo "Team workflow: AGENTS.md. Commands: /goal <goal>, /next. Fast checks: just check."
exit 0
