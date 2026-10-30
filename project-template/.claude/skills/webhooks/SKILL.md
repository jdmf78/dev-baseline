---
name: webhooks
description: Set up, test and run GitHub webhooks for this project. Covers forwarding for local development, a public HTTPS endpoint on this machine, registering the webhook on GitHub, checking deliveries, and redelivering failures. Use when the project should react to GitHub events.
---

# Webhooks playbook

Do every step yourself. The receiver is `services/webhooks/`: it verifies the
signature, skips duplicate deliveries and replies within GitHub's 10 seconds.
Event logic goes in `services/webhooks/src/handlers.js`, one function per
event, with tests in `services/webhooks/test/`.

## Settings (in `.env`)

- `WEBHOOK_SECRET`: if empty, set it to the output of `openssl rand -hex 32`.
- `WEBHOOK_EVENTS`: comma-separated events, default `push,pull_request,issues`.
  Add a handler for each new event.
- `GITHUB_REPO`: `gh repo view --json nameWithOwner --jq .nameWithOwner`.

## Development (no public URL needed)

1. `tmux new-window -d -n webhooks 'just dev'` starts the receiver.
2. `tmux new-window -d -n forward 'just webhook-forward'` relays the repo's
   real events to it.
3. `just webhook-ping` must answer `{"accepted": ...}`.

## Public endpoint on this machine

1. Base domain: `cat ~/.config/dev-baseline/domain`. If it's missing, follow
   "Needs a human".
2. In `.env`, set `DOMAIN=<project>.<domain>`.
3. `just up`, then
   `curl -s -o /dev/null -w '%{http_code}' https://$DOMAIN/webhook` must print
   `405` (the endpoint only accepts POST).
4. `just webhook-register https://$DOMAIN/webhook` creates or updates the
   GitHub webhook with the same secret and events.
5. Check the first delivery:
   `gh api repos/{owner}/{repo}/hooks --jq '.[] | select(.config.url | endswith("/webhook")) | .id'`,
   then `gh api repos/{owner}/{repo}/hooks/<id>/deliveries --jq '.[0] | {event, status_code}'`.
   It should be a `ping` with `202`.
6. After downtime: `just webhook-redeliver https://$DOMAIN/webhook 48`.

## Needs a human

- A DNS record, only when there's no base domain. Until then, keep using
  forwarding (development) instead.
