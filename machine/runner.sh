#!/usr/bin/env bash
# Makes this machine a GitHub Actions self-hosted runner for your project, so
# its workflow jobs (CI, image builds, deploys) run here instead of on GitHub's
# machines. Run it after login.sh, or use install.sh --runner. Safe to re-run:
# it repairs what's missing and leaves a working runner alone.
#
# GitHub's runner won't run as root ("Must not run with sudo") unless
# RUNNER_ALLOW_RUNASROOT=1 is set. This script runs it as its own user,
# `runner`, as a systemd service, with Docker and passwordless sudo like
# GitHub's own runners. Then it sets the repo variable RUNS_ON=self-hosted,
# which the project template's workflows read to send their jobs here.
#
# Usage: machine/runner.sh [--project OWNER/REPO] [--remove]
#   --project OWNER/REPO   defaults to your project (login.sh --project)
#   --remove               unregister this machine's runner and delete it
set -euo pipefail

STATE="$HOME/.config/dev-baseline"
RUNNER_USER=runner
PROJECT="" REMOVE=0 RESTART=0 RUNNER_HOME="" DIR=""
RUN_AS=()

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
yes_no() { local ans; read -r -p "$1 [y/N] " ans || ans=n; [[ $ans == [Yy]* ]]; }
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
systemd_running() { [[ -d /run/systemd/system ]]; }

while (($#)); do
  case $1 in
    --project) PROJECT=${2:?--project needs OWNER/REPO}; shift 2 ;;
    --remove)  REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; die "unknown option: $1" ;;
  esac
done
[[ -n $PROJECT ]] || PROJECT=$(cat "$STATE/project" 2>/dev/null || true)
[[ -n $PROJECT ]] || die "No project set: run with --project OWNER/REPO"
[[ $PROJECT =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--project must look like OWNER/REPO (got: $PROJECT)"
gh auth status >/dev/null 2>&1 || die "Sign in to GitHub first: ~/dev-baseline/machine/login.sh"
read -r PRIVATE ADMIN < <(gh api "repos/$PROJECT" --jq '"\(.private) \(.permissions.admin)"' 2>/dev/null) || true
[[ ${ADMIN:-} == true ]] ||
  die "Adding a runner needs admin rights on $PROJECT, which this GitHub login doesn't have (or it can't see the repo)."
NAME=$(hostname -s)
SESSION="runner-${PROJECT##*/}"

set_dir() {
  RUNNER_HOME=$(getent passwd "$RUNNER_USER" | cut -d: -f6)
  DIR="$RUNNER_HOME/actions-runner/${PROJECT/\//-}"
  # As the runner user, in its folder, with a clean environment: config.sh
  # records PATH and a few variables as the starting point of every job.
  RUN_AS=(runuser -u "$RUNNER_USER" -- env -i -C "$DIR" HOME="$RUNNER_HOME" USER="$RUNNER_USER"
    LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
}
as_runner() { as_root "${RUN_AS[@]}" "$@"; }
# The runner's home isn't readable by other users, so check its files as root.
has() { as_root test -e "$DIR/$1"; }
# svc.sh (written by config.sh) manages the runner's systemd unit.
svc() { (cd "$DIR" && as_root ./svc.sh "$@" >/dev/null); }

# This machine's runner on GitHub: online, offline, or empty if not registered.
runner_status() {
  gh api --paginate "repos/$PROJECT/actions/runners" --jq ".runners[] | select(.name == \"$NAME\") | .status"
}

stop_runner() {
  if has .service; then svc uninstall || true; fi
  as_root tmux kill-session -t "$SESSION" 2>/dev/null || true
}

check_public() {
  [[ $PRIVATE == false ]] || return 0
  warn "$PROJECT is public. GitHub advises self-hosted runners for private repos only: a pull"
  warn "request from anyone's fork can change a workflow and run its own code on this machine."
  yes_no "Add the runner anyway, with outside contributors' workflow runs waiting for your approval?" ||
    die "Stopped; nothing was changed."
  gh api -X PUT "repos/$PROJECT/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null ||
    warn "Couldn't turn on that approval; do it under Settings > Actions > General."
}

runner_user() {
  log "User $RUNNER_USER (GitHub's runner won't run as root)"
  id "$RUNNER_USER" >/dev/null 2>&1 || as_root useradd --create-home --shell /bin/bash "$RUNNER_USER"
  set_dir
  # Docker and passwordless sudo, as on GitHub's runners, so workflows run
  # unchanged. Both are root-equivalent: keep one project per container.
  if getent group docker >/dev/null && ! id -nG "$RUNNER_USER" | grep -qw docker; then
    as_root usermod -aG docker "$RUNNER_USER"
    RESTART=1
  fi
  local rule="/etc/sudoers.d/$RUNNER_USER"
  if ! as_root test -f "$rule"; then
    if ! command -v sudo >/dev/null; then
      as_root apt-get update -qq
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo
    fi
    echo "$RUNNER_USER ALL=(ALL) NOPASSWD:ALL" | as_root tee "$rule" >/dev/null
    as_root chmod 0440 "$rule"
    as_root visudo -cqf "$rule" || { as_root rm -f "$rule"; die "sudo rejected $rule"; }
  fi
}

# Download once, checked against GitHub's published checksum; after that the
# runner updates itself.
download_runner() {
  has config.sh && return 0
  local arch tag file sum tmp
  case $(dpkg --print-architecture) in
    amd64) arch=x64 ;;
    arm64) arch=arm64 ;;
    armhf) arch=arm ;;
    *)     die "GitHub's runner isn't built for $(dpkg --print-architecture)." ;;
  esac
  tag=$(gh api repos/actions/runner/releases/latest --jq .tag_name)
  file="actions-runner-linux-$arch-${tag#v}.tar.gz"
  sum=$(gh api "repos/actions/runner/releases/tags/$tag" --jq ".assets[] | select(.name == \"$file\") | .digest")
  [[ $sum == sha256:* ]] || die "GitHub lists no checksum for $file; not installing it."
  log "GitHub Actions runner $tag ($arch) in $DIR"
  tmp=$(mktemp)
  curl -fsSL "https://github.com/actions/runner/releases/download/$tag/$file" -o "$tmp"
  echo "${sum#sha256:}  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; die "$file doesn't match its checksum."; }
  as_root install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$DIR"
  as_root tar -xzf "$tmp" -C "$DIR"
  as_root chown -R "$RUNNER_USER:$RUNNER_USER" "$DIR"
  rm -f "$tmp"
  # The libraries it needs: ICU, Kerberos, OpenSSL, LTTng.
  (cd "$DIR" && as_root ./bin/installdependencies.sh >/dev/null) ||
    warn "Some of the runner's libraries didn't install; config.sh below names what's missing."
}

register_runner() {
  if has .runner; then
    [[ -z $(runner_status) ]] || return 0
    warn "Runner $NAME was removed on GitHub; registering it again."
    stop_runner
    as_root rm -f "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams"
  fi
  log "Registering runner $NAME for $PROJECT"
  local token
  # The token expires within an hour and can only register runners. --replace
  # takes over a runner of the same name left by an earlier install.
  token=$(gh api -X POST "repos/$PROJECT/actions/runners/registration-token" --jq .token)
  as_runner ./config.sh --unattended --replace --url "https://github.com/$PROJECT" \
    --token "$token" --name "$NAME"
}

start_runner() {
  if systemd_running; then
    if ! has .service; then
      svc install "$RUNNER_USER"
    elif ((RESTART)); then
      as_root systemctl restart "$(as_root cat "$DIR/.service")"
    fi
    svc start
  else
    # Containers without systemd: a tmux session, which ends when the machine restarts.
    as_root tmux has-session -t "$SESSION" 2>/dev/null ||
      as_root tmux new-session -d -s "$SESSION" "$(printf '%q ' "${RUN_AS[@]}" ./run.sh)"
    warn "No systemd here, so the runner runs in root's tmux session $SESSION. Re-run this after a restart."
  fi
  log "Waiting for the runner to come online"
  for _ in {1..15}; do
    [[ $(runner_status) != online ]] || return 0
    sleep 2
  done
  warn "Runner $NAME isn't online yet. Its logs: $DIR/_diag/Runner_*.log"
}

remove_runner() {
  { id "$RUNNER_USER" >/dev/null 2>&1 && set_dir && as_root test -d "$DIR"; } ||
    die "There's no runner for $PROJECT on this machine."
  log "Removing runner $NAME from $PROJECT"
  stop_runner
  if has .runner; then
    local token
    token=$(gh api -X POST "repos/$PROJECT/actions/runners/remove-token" --jq .token)
    as_runner ./config.sh remove --token "$token" ||
      warn "Couldn't unregister it; delete $NAME under Settings > Actions > Runners."
  fi
  as_root rm -rf "$DIR"
  if [[ $(gh api "repos/$PROJECT/actions/runners" --jq .total_count) == 0 ]]; then
    gh variable delete RUNS_ON --repo "$PROJECT" >/dev/null 2>&1 || true
    echo "No runners left for $PROJECT, so its jobs run on GitHub's machines again."
  fi
}

if ((REMOVE)); then
  remove_runner
  exit 0
fi
check_public
runner_user
download_runner
register_runner
start_runner
log "Sending the project's jobs here: repo variable RUNS_ON=self-hosted"
gh variable set RUNS_ON --body self-hosted --repo "$PROJECT"

cat <<EOF

Runner $NAME works for $PROJECT (GitHub: Settings > Actions > Runners).
  Jobs   The project template's workflows run here while RUNS_ON is set.
         Other workflows: put runs-on: self-hosted on the jobs that should.
  Runs   as user $RUNNER_USER, from $DIR
  Undo   gh variable delete RUNS_ON --repo $PROJECT   (jobs back to GitHub's machines)
         ~/dev-baseline/machine/runner.sh --remove     (remove the runner as well)
EOF
