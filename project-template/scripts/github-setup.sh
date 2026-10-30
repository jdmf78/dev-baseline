#!/usr/bin/env bash
# Apply baseline GitHub settings to a repo. Idempotent: re-run any time.
#
# Usage: scripts/github-setup.sh [--repo OWNER/NAME] [--webhook-url URL] [--labels-only]
#   --repo          defaults to the repo of the current directory
#   --webhook-url   create or update a repo webhook pointing at your deployed
#                   service (e.g. https://hooks.example.com/webhook); the
#                   secret is WEBHOOK_SECRET from .env, generated if empty
#   --labels-only   only create the labels the agent team uses
# Needs gh (logged in as a repo admin, admin:repo_hook scope), jq and openssl.
set -euo pipefail

REPO="" WEBHOOK_URL="" LABELS_ONLY=0
EVENTS='["push","pull_request","issues"]'

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }

while (($#)); do
  case $1 in
    --repo)        REPO=${2:?--repo needs OWNER/NAME}; shift 2 ;;
    --webhook-url) WEBHOOK_URL=${2:?--webhook-url needs a URL}; shift 2 ;;
    --labels-only) LABELS_ONLY=1; shift ;;
    -h|--help)     awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *)             echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[[ -n $REPO ]] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

log "Labels for the agent team"
while IFS='|' read -r name color desc; do
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null
done <<'EOF'
agent|5319e7|Work item or PR for the agent team
agent:in-progress|fbca04|A developer agent is working on it
agent:approved|0e8a16|Reviewer found no blocking issues
agent:changes|d93f0b|Reviewer requested changes
blocked|b60205|Needs a human decision
EOF
((LABELS_ONLY)) && exit 0

log "Merge settings for $REPO: squash only, delete merged branches, allow auto-merge"
gh api -X PATCH "repos/$REPO" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

log "Dependabot alerts and security updates"
gh api -X PUT "repos/$REPO/vulnerability-alerts" --silent
gh api -X PUT "repos/$REPO/automated-security-fixes" --silent

log "Secret scanning with push protection"
security='{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
if ! gh api -X PATCH "repos/$REPO" --silent --input - <<<"$security" 2>/dev/null; then
  warn "Not available here (private repos need GitHub Secret Protection). gitleaks in CI still runs."
fi

log "Ruleset 'main': changes via PR only, CI must pass, no force-push or deletion"
ruleset=$(jq -n '{
  name: "main",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "required_linear_history" },
    { type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: true } },
    { type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: true,
        required_status_checks: [ { context: "ci" } ] } }
  ]
}')
id=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "main") | .id' 2>/dev/null || true)
if [[ -n $id ]]; then
  method=PUT path="repos/$REPO/rulesets/$id"
else
  method=POST path="repos/$REPO/rulesets"
fi
if ! gh api -X "$method" "$path" --silent --input - <<<"$ruleset"; then
  warn "Rulesets on private repos need GitHub Pro or Team (or a public repo)."
fi

log "Environment 'production' (add required reviewers under Settings > Environments)"
gh api -X PUT "repos/$REPO/environments/production" --silent

if [[ -n $WEBHOOK_URL ]]; then
  log "Repository webhook -> $WEBHOOK_URL"
  [[ -f .env ]] || cp .env.example .env
  secret=$(sed -n 's/^WEBHOOK_SECRET=//p' .env | tail -1)
  if [[ -z $secret ]]; then
    secret=$(openssl rand -hex 32)
    tmp=$(mktemp)
    grep -v '^WEBHOOK_SECRET=' .env >"$tmp" || true
    echo "WEBHOOK_SECRET=$secret" >>"$tmp"
    mv "$tmp" .env
    chmod 600 .env
    echo "Generated WEBHOOK_SECRET and saved it to .env."
  fi
  hook=$(jq -n --arg url "$WEBHOOK_URL" --arg secret "$secret" --argjson events "$EVENTS" \
    '{name: "web", active: true, events: $events,
      config: {url: $url, content_type: "json", secret: $secret, insecure_ssl: "0"}}')
  hook_id=$(gh api --paginate "repos/$REPO/hooks" --jq ".[] | select(.config.url == \"$WEBHOOK_URL\") | .id")
  if [[ -n $hook_id ]]; then
    gh api -X PATCH "repos/$REPO/hooks/$hook_id" --silent --input - <<<"$(jq 'del(.name)' <<<"$hook")"
  else
    gh api -X POST "repos/$REPO/hooks" --silent --input - <<<"$hook"
  fi
  echo "The server running the service needs the same WEBHOOK_SECRET in its .env."
fi

cat <<EOF

Done for $REPO. One-time steps left:
  - Claude in GitHub: run /install-github-app inside Claude Code, or install
    https://github.com/apps/claude and run: gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $REPO
  - Claude review of every PR: gh variable set CLAUDE_REVIEW --body true --repo $REPO
  - Codex PR review (optional): gh secret set OPENAI_API_KEY --repo $REPO
                                gh variable set CODEX_REVIEW --body true --repo $REPO
  - Deploys, once release.yml has a target: gh variable set DEPLOY_ENABLED --body true --repo $REPO
EOF
