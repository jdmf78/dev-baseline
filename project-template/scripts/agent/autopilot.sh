#!/usr/bin/env bash
# Unattended build loop on top of GSD Core. Runs /gsd-autonomous headless until
# the milestone is built and verified, then /gsd-ship opens the PR. Stops when
# the PR exists, a run fails, or MAX_RUNS is reached. Run it inside `dev`
# (tmux) so it survives SSH drops. Start the project first with
# /gsd-new-project (or /gsd-new-milestone) in Claude Code, Codex or OpenCode.
# The unattended runs use Claude Code, so it must be installed.
#
# Usage: scripts/agent/autopilot.sh [MAX_RUNS]        (default 3)
# Environment:
#   AUTOPILOT_BUDGET_USD  spending cap per run, estimated (default 25)
#   AUTO_MERGE=1          merge the milestone PR once CI passes;
#                         without it the PR waits for you
set -euo pipefail

max_runs=${1:-3}
budget=${AUTOPILOT_BUDGET_USD:-25}
config=.planning/config.json

cd "$(git rev-parse --show-toplevel)"
if ! command -v claude >/dev/null; then
  echo "The autopilot runs on Claude Code, which isn't installed here." >&2
  echo "Add it: ~/dev-baseline/machine/bootstrap.sh --agents claude,codex,opencode (list the ones you want)" >&2
  exit 1
fi
if [[ ! -f $config ]]; then
  echo "No GSD project here yet. In your AI tool, run /gsd-new-project first." >&2
  exit 1
fi

# Unattended settings: decide without asking, and build the milestone on its
# own branch (gsd/...), because main only accepts reviewed PRs.
tmp=$(mktemp)
jq '.mode = "yolo" | .workflow.skip_discuss = true | .workflow.auto_advance = true
  | .git.branching_strategy = "milestone"' "$config" >"$tmp"
mv "$tmp" "$config"
mkdir -p .agent-logs

run() {
  local log
  log=".agent-logs/$(date -u +%Y%m%dT%H%M%SZ)-${1//[^a-z]/}.json"
  echo "== $1 (log: $log)"
  if ! claude -p "$1" --permission-mode auto --permission-prompts none \
    --max-budget-usd "$budget" --output-format json >"$log"; then
    echo "The run failed; see $log" >&2
    exit 1
  fi
  jq -r '"  estimated cost: $\((.total_cost_usd // 0) * 100 | round / 100)", .result' "$log" | tail -n 20
}

shipped_prs() {
  gh pr list --state open --author @me --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("gsd/")) | .number'
}

# Merging happens here, under your own login, never inside the agents.
# Relies on scripts/github-setup.sh having protected main (required `ci` check).
merge() {
  local n
  for n in $(shipped_prs); do
    gh pr update-branch "$n" >/dev/null 2>&1 || true # rules require an up-to-date branch
    if gh pr merge "$n" --auto --squash --delete-branch >/dev/null 2>&1; then
      echo "  #$n merges as soon as its checks pass"
    elif gh pr checks "$n" >/dev/null 2>&1 && gh pr merge "$n" --squash --delete-branch >/dev/null 2>&1; then
      echo "  merged #$n (all checks passed)"
    else
      echo "  #$n waits: checks not passed yet, or merging is blocked"
    fi
  done
}

for ((i = 1; i <= max_runs; i++)); do
  echo "=== Run $i of $max_runs"
  run "/gsd-autonomous --text"
  run "/gsd-ship"
  if [[ -n $(shipped_prs) ]]; then
    echo "The milestone is shipped as a PR: $(gh pr list --author @me --state open --json url --jq '.[0].url')"
    if [[ ${AUTO_MERGE:-0} == 1 ]]; then merge; else echo "Review and merge it, or re-run with AUTO_MERGE=1."; fi
    exit 0
  fi
done
echo "Not shipped after $max_runs runs. Check progress with /gsd-progress, then run again."
