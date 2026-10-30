#!/usr/bin/env bash
# Unattended team loop. Runs Claude Code headless with /next, one wave per
# run, until no team issues or PRs are open, a run fails, or MAX_RUNS is hit.
# Run it inside `dev` (tmux) so it survives SSH drops.
#
# Usage: scripts/agent/autopilot.sh [MAX_RUNS]        (default 5)
# Environment:
#   AUTOPILOT_BUDGET_USD  spending cap per run, estimated (default 10)
#   AUTOPILOT_PARALLEL    developers per wave (default 3)
#   AUTOPILOT_PAUSE       seconds between runs, for CI to finish (default 180)
#   AUTO_MERGE=1          merge PRs the reviewer approved once CI passes.
#                         Without it, approved PRs wait for you.
set -euo pipefail

max_runs=${1:-5}
budget=${AUTOPILOT_BUDGET_USD:-10}
parallel=${AUTOPILOT_PARALLEL:-3}
pause=${AUTOPILOT_PAUSE:-180}

cd "$(git rev-parse --show-toplevel)"
if [[ -n $(git status --porcelain) ]]; then
  echo "Uncommitted changes here: commit or stash them first." >&2
  exit 1
fi
mkdir -p .agent-logs

count() { gh "$1" list --label agent --state open --json number --jq length; }

# Merging happens here, under your own login, never inside the agents.
# Relies on scripts/github-setup.sh having protected main (required `ci` check).
merge_approved() {
  [[ ${AUTO_MERGE:-0} == 1 ]] || return 0
  local n
  for n in $(gh pr list --label agent:approved --state open --json number --jq '.[].number'); do
    gh pr update-branch "$n" >/dev/null 2>&1 || true # rules require an up-to-date branch
    if gh pr merge "$n" --auto --squash --delete-branch >/dev/null 2>&1; then
      echo "  #$n merges as soon as its checks pass"
    elif gh pr checks "$n" >/dev/null 2>&1 && gh pr merge "$n" --squash --delete-branch >/dev/null 2>&1; then
      # Auto-merge unavailable (e.g. already mergeable): merge only when every check passed.
      echo "  merged #$n (all checks passed)"
    else
      echo "  #$n waits: checks not passed yet, or merging is blocked"
    fi
  done
}

for ((run = 1; run <= max_runs; run++)); do
  git switch -q main
  git pull -q --ff-only
  issues=$(count issue)
  prs=$(count pr)
  if ((issues == 0 && prs == 0)); then
    echo "No open team issues or PRs: the goal is done (or not planned yet; run /goal)."
    exit 0
  fi

  log=".agent-logs/run-$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "== Run $run/$max_runs: $issues open issues, $prs open PRs (log: $log)"
  if ! claude -p "/next $parallel" --permission-mode auto --permission-prompts none \
    --max-budget-usd "$budget" --output-format json >"$log"; then
    echo "The run failed; see $log" >&2
    exit 1
  fi
  jq -r '"  estimated cost: $\((.total_cost_usd // 0) * 100 | round / 100)", .result' "$log" | tail -n 30
  grep -q 'GOAL COMPLETE' "$log" && { echo "Goal complete."; merge_approved; exit 0; }

  merge_approved
  ((run < max_runs)) && sleep "$pause"
done
echo "Reached $max_runs runs. Run again to continue."
