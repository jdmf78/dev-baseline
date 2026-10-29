#!/usr/bin/env bash
# Interactive sign-in, once per machine, after bootstrap.sh: GitHub CLI,
# an anonymous git identity, this machine's SSH key, gh-webhook, Codex, Claude Code.
set -euo pipefail

KEY="$HOME/.ssh/github_ed25519.pub"
SIGNERS="$HOME/.config/git/allowed_signers"
SCOPES=(admin:public_key admin:ssh_signing_key admin:repo_hook workflow)

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

[[ -f $KEY ]] || { echo "Missing $KEY: run bootstrap.sh first." >&2; exit 1; }

step "GitHub CLI: open the printed URL on any device and enter the code"
if gh auth status >/dev/null 2>&1; then
  granted=$(gh api -i user 2>/dev/null | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r')
  missing=()
  for s in "${SCOPES[@]}"; do [[ ", $granted," == *", $s,"* ]] || missing+=("$s"); done
  if ((${#missing[@]})); then
    gh auth refresh --hostname github.com --scopes "$(IFS=,; echo "${missing[*]}")"
  else
    echo "Already logged in with the needed scopes."
  fi
else
  gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web \
    --scopes "$(IFS=,; echo "${SCOPES[*]}")"
fi

step "Git identity (GitHub username + private noreply email, unless you set your own)"
read -r login id < <(gh api user --jq '"\(.login) \(.id)"')
[[ -n $(git config --global user.name || true) ]] || git config --global user.name "$login"
[[ -n $(git config --global user.email || true) ]] ||
  git config --global user.email "$id+$login@users.noreply.github.com"
email=$(git config --global user.email)
echo "Commits will be authored as: $(git config --global user.name) <$email>"
line="$email namespaces=\"git\" $(cut -d' ' -f1,2 "$KEY")"
grep -qxF "$line" "$SIGNERS" 2>/dev/null || echo "$line" >>"$SIGNERS"
cat <<'EOF'
Once per GitHub account, under Settings > Emails, turn on "Keep my email
addresses private" and "Block command line pushes that expose my email".
EOF

step "Upload this machine's SSH key (authentication + commit signing)"
pub=$(cut -d' ' -f1,2 "$KEY")
title="$(hostname -s) ($(date +%Y-%m-%d))"
if gh api --paginate user/keys --jq '.[].key' | grep -qxF "$pub"; then
  echo "Authentication key already on GitHub."
else
  gh ssh-key add "$KEY" --type authentication --title "$title"
fi
if gh api --paginate user/ssh_signing_keys --jq '.[].key' | grep -qxF "$pub"; then
  echo "Signing key already on GitHub."
else
  gh ssh-key add "$KEY" --type signing --title "$title"
fi
out=$(ssh -T git@github.com 2>&1 || true)
if [[ $out == *"successfully authenticated"* ]]; then echo "SSH to GitHub works."; else echo "$out"; fi

step "gh-webhook extension (forwards GitHub webhooks to a local port)"
gh extension list | grep -q 'cli/gh-webhook' || gh extension install cli/gh-webhook

step "Codex"
if codex login status >/dev/null 2>&1; then
  echo "Already logged in."
elif ! codex login --device-auth; then
  cat <<'EOF'
Device-code login was refused. Either enable device code login for Codex in
your ChatGPT security settings (a workspace admin controls this on business
plans), or tunnel the browser callback from your laptop and log in normally:
  ssh -L 1455:localhost:1455 <this-server>     then run: codex login
EOF
fi

step "Claude Code"
cat <<'EOF'
Start a persistent session and log in there:
  dev            # tmux session that survives SSH drops
  claude         # pick your account; on a server it prints a URL to open on
                 # your laptop, then you paste the code back
For GitHub Actions later, `claude setup-token` prints a long-lived token for
the CLAUDE_CODE_OAUTH_TOKEN repo secret (Pro/Max/Team/Enterprise plans).
EOF
