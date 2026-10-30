#!/usr/bin/env bash
# Interactive sign-in, once per machine, after bootstrap.sh (install.sh runs
# both): GitHub CLI, an anonymous git identity, this machine's SSH key,
# gh-webhook, Codex and Claude Code. Then it clones and sets up your project.
# Re-run with another --project to switch, or to add a second project.
#
# Usage: machine/login.sh [--project OWNER/REPO]
#   --project OWNER/REPO   defaults to the repo given to bootstrap.sh --project
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$HOME/.config/dev-baseline"
KEY="$HOME/.ssh/github_ed25519.pub"
SIGNERS="$HOME/.config/git/allowed_signers"
SCOPES=(admin:public_key admin:ssh_signing_key admin:repo_hook workflow)
PROJECT=""

# Works straight after bootstrap, before a new shell has picked up the PATH.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
yes_no() { local ans; read -r -p "$1 [Y/n] " ans || ans=n; [[ ${ans:-y} == [Yy]* ]]; }

while (($#)); do
  case $1 in
    --project) PROJECT=${2:?--project needs OWNER/REPO}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n $PROJECT ]] || PROJECT=$(cat "$STATE/project" 2>/dev/null || true)
[[ -f $KEY ]] || { echo "Missing $KEY: run bootstrap.sh first." >&2; exit 1; }

# Create the project on GitHub if it's missing (after asking), clone it to
# ~/code/NAME, install its tools, and make `dev` open there. An empty repo can
# be started from project-template.
setup_project() {
  local dir="$HOME/code/${PROJECT##*/}" seeded=0
  step "Project $PROJECT -> $dir"
  if ! gh repo view "$PROJECT" --json name >/dev/null 2>&1; then
    if yes_no "$PROJECT isn't on GitHub (or this login can't see it). Create it now, private?"; then
      gh repo create "$PROJECT" --private
    else
      echo "Create it, then re-run: ~/dev-baseline/machine/login.sh --project $PROJECT" >&2
      return 1
    fi
  fi
  mkdir -p "$STATE" "$HOME/code"
  echo "$PROJECT" >"$STATE/project"
  echo "$dir" >"$STATE/project-dir"
  gh config set git_protocol ssh --host github.com
  if [[ -d $dir/.git ]]; then
    git -C "$dir" pull --ff-only --quiet 2>/dev/null || echo "Left $dir as it is (local changes, or nothing to pull)."
  else
    gh repo clone "$PROJECT" "$dir"
  fi

  if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null && yes_no "$PROJECT is empty. Start it from the project template?"; then
    cp -R "$KIT/project-template/." "$dir/"
    seeded=1
  fi
  if [[ -f $dir/mise.toml || -f $dir/.mise.toml ]]; then
    (cd "$dir" && mise trust --quiet && mise install)
  fi
  if [[ -f $dir/justfile ]] && grep -q '^setup:' "$dir/justfile"; then
    (cd "$dir" && just setup)
  fi
  if ((seeded)); then
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore: start from the dev-baseline project template"
    git -C "$dir" push -q -u origin HEAD
    echo "Pushed the template to $PROJECT."
    if yes_no "Apply branch protection and repo settings now (scripts/github-setup.sh)?"; then
      (cd "$dir" && scripts/github-setup.sh)
    fi
  fi
}

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

step "Codex: open the printed URL on any device and enter the code"
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

step "Claude Code: open the printed URL on your laptop, approve, paste the code back"
if claude auth status >/dev/null 2>&1; then
  echo "Already logged in."
else
  echo "(To bill an Anthropic Console API account instead of a subscription: claude auth login --console)"
  claude auth login || echo "Claude login didn't finish; run: claude auth login" >&2
fi

if [[ -n $PROJECT ]]; then
  setup_project
else
  step "Project"
  echo "None set. Re-run with --project OWNER/REPO to clone your development repo."
fi

step "Ready"
cat <<'EOF'
Open a new shell so PATH and the `dev` command load:  exec bash -l
Then:
  dev      tmux session in your project that survives SSH drops
  claude   Claude Code        codex   Codex
EOF
