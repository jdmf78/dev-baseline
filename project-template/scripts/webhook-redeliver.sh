#!/usr/bin/env bash
# Redeliver webhook deliveries that never succeeded. GitHub does not retry
# failed deliveries itself: run this after downtime, by hand or from cron.
#
# Usage: scripts/webhook-redeliver.sh WEBHOOK_URL [HOURS]   (default: 24)
#   REPO=owner/name overrides the repo of the current directory.
# Needs gh with the admin:repo_hook scope, and jq.
set -euo pipefail

url=${1:?usage: webhook-redeliver.sh WEBHOOK_URL [HOURS]}
hours=${2:-24}
repo=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
since=$(($(date +%s) - hours * 3600))

hook_id=$(gh api --paginate "repos/$repo/hooks" --jq ".[] | select(.config.url == \"$url\") | .id")
if [[ -z $hook_id ]]; then
  echo "No webhook with URL $url on $repo" >&2
  exit 1
fi

# For each delivery GUID in the window with no successful attempt, take the latest attempt.
failed=$(
  gh api --paginate "repos/$repo/hooks/$hook_id/deliveries?per_page=100" |
    jq -rs --argjson since "$since" '
      add
      | map(select((.delivered_at | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $since))
      | group_by(.guid)
      | map(select(any(.[]; .status_code >= 200 and .status_code < 300) | not) | max_by(.delivered_at))
      | .[].id'
)

count=0
while read -r id; do
  [[ -n $id ]] || continue
  if gh api -X POST "repos/$repo/hooks/$hook_id/deliveries/$id/attempts" --silent; then
    count=$((count + 1))
  else
    echo "Redelivery of $id failed" >&2
  fi
done <<<"$failed"
echo "Requested $count redeliveries for $repo (last $hours h)."
