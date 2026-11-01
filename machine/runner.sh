#!/usr/bin/env bash
# GitHub Actions self-hosted runners, in the same place on every machine and
# run by the user `runner`. bootstrap.sh installs the first one ready to use
# (--prepare) in /home/runner/actions-runner, connected to no repo. Running
# this script connects it to your project, so the project's workflow jobs (CI,
# image builds, deploys) run here, and keeps it running as a systemd service.
# A runner serves one repo, so each further repo gets a runner of its own, in
# /home/runner/actions-runner-OWNER-REPO with its own service. Safe to re-run:
# it repairs what's missing and leaves a working runner alone.
#
# GitHub's runner won't run as root ("Must not run with sudo") unless
# RUNNER_ALLOW_RUNASROOT=1 is set. Instead, `runner` has Docker and
# passwordless sudo, like GitHub's own runners. Connecting also sets the repo
# variable RUNS_ON=self-hosted, which the project template's workflows read to
# send their jobs here.
#
# Usage: machine/runner.sh [--project OWNER/REPO] [--status | --remove] | --prepare
#   --project OWNER/REPO   repo to connect a runner to (default: your project, from
#                          login.sh); with --status or --remove, that repo's runner
#   --status               every runner here: its repo, online or not, how it runs, its logs
#   --remove               disconnect a runner from its repo (with several, pick it by --project)
#   --prepare              install or update the first runner, without a repo (bootstrap.sh runs this)
set -euo pipefail

STATE="$HOME/.config/dev-baseline"
RUNNER_USER=runner
RUNNER_HOME=/home/runner
MAIN=$RUNNER_HOME/actions-runner
HOST=$(hostname -s)
MODE=connect PROJECT="" PRIVATE="" RESTART=0
DIRS=()

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
yes_no() { local ans; read -r -p "$1 [y/N] " ans || ans=n; [[ $ans == [Yy]* ]]; }
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
systemd_running() { [[ -d /run/systemd/system ]]; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

while (($#)); do
  case $1 in
    --project) PROJECT=${2:?--project needs OWNER/REPO}; shift 2 ;;
    --prepare) MODE=prepare; shift ;;
    --status)  MODE=status; shift ;;
    --remove)  MODE=remove; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; die "unknown option: $1" ;;
  esac
done

# Work on the runner in folder $1, with its own tmux session where there's no
# systemd. Commands run as the runner user, in its folder, with a clean
# environment: config.sh records PATH and a few variables as the starting
# point of every job.
use_dir() {
  DIR=$1 SESSION=${1##*/} NAME=$HOST
  SESSION=${SESSION//[.:]/_}
  RUN_AS=(runuser -u "$RUNNER_USER" -- env -i -C "$DIR" HOME="$RUNNER_HOME" USER="$RUNNER_USER"
    LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
}
use_dir "$MAIN"

# Every runner folder here: the first runner's, then one per further repo.
runner_dirs() {
  local d
  DIRS=("$MAIN")
  while IFS= read -r d; do DIRS+=("$d"); done < <(as_root find "$RUNNER_HOME" -mindepth 1 \
    -maxdepth 1 -type d -name 'actions-runner-*' 2>/dev/null | sort)
}

as_runner() { as_root "${RUN_AS[@]}" "$@"; }
# The runner's home isn't readable by other users, so check its files as root.
has() { as_root test -e "$DIR/$1"; }
# svc.sh (written by config.sh) manages the runner's systemd unit.
svc() { (cd "$DIR" && as_root ./svc.sh "$@" >/dev/null); }

# A value from .runner, which config.sh writes when it connects to a repo.
setting() { as_root grep -oiE "\"$1\": *\"[^\"]*\"" "$DIR/.runner" 2>/dev/null | cut -d'"' -f4; }
# Its name on GitHub, once connected.
runner_name() {
  local name
  name=$(setting agentName) || true
  NAME=${name:-$NAME}
}
connected_repo() {
  local url
  url=$(setting gitHubUrl) || true
  url=${url#https://github.com/}
  echo "${url%/}"
}
# Where GitHub's API keeps the runners of $PROJECT: a repo, or an organization
# for a runner connected to one by hand (docs/runner.md).
scope() { if [[ $PROJECT == */* ]]; then echo "repos/$PROJECT"; else echo "orgs/$PROJECT"; fi; }

# The GitHub login must be able to manage the repo's runners (admin rights).
need_github() {
  local admin
  gh auth status >/dev/null 2>&1 || die "Sign in to GitHub first: ~/dev-baseline/machine/login.sh"
  [[ $PROJECT == */* ]] || return 0
  read -r PRIVATE admin < <(gh api "repos/$PROJECT" --jq '"\(.private) \(.permissions.admin)"' 2>/dev/null) || true
  [[ ${admin:-} == true ]] ||
    die "Managing runners for $PROJECT needs admin rights there, which this GitHub login doesn't have (or it can't see the repo)."
}

# This runner on GitHub: online, offline, or empty if it isn't registered.
runner_status() {
  gh api --paginate "$(scope)/actions/runners" --jq ".runners[] | select(.name == \"$NAME\") | .status"
}

stop_runner() {
  if has .service; then svc uninstall || true; fi
  as_root tmux kill-session -t "$SESSION" 2>/dev/null || true
  stop_by_hand
}

# A runner started by hand (./run.sh in a terminal, tmux or screen) holds the
# connection to GitHub the service needs, so stop it before the service starts.
started_by_hand() { as_root pgrep -f "$DIR/bin/Runner.Listener" >/dev/null; }
stop_by_hand() {
  started_by_hand || return 0
  warn "Stopping the runner started by hand in $DIR, so the service can take over."
  as_root pkill -INT -f "$DIR/bin/Runner.Listener" || true
  for _ in {1..30}; do
    started_by_hand || return 0
    sleep 1
  done
  die "It's still running, maybe finishing a job. Stop it with Ctrl-C where it runs, then re-run this."
}

check_public() {
  [[ $PRIVATE == false ]] || return 0
  warn "$PROJECT is public. GitHub advises self-hosted runners for private repos only: a pull"
  warn "request from anyone's fork can change a workflow and run its own code on this machine."
  yes_no "Connect the runner anyway, with outside contributors' workflow runs waiting for your approval?" ||
    die "Stopped; nothing was changed."
  gh api -X PUT "repos/$PROJECT/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null ||
    warn "Couldn't turn on that approval; do it under Settings > Actions > General."
}

runner_user() {
  id "$RUNNER_USER" >/dev/null 2>&1 ||
    as_root useradd --create-home --home-dir "$RUNNER_HOME" --shell /bin/bash "$RUNNER_USER"
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

# Earlier versions of this script kept runners in actions-runner/OWNER-REPO.
# Move such a runner up into the fixed place.
move_old_layout() {
  local old
  has config.sh && return 0
  old=$(as_root find "$DIR" -mindepth 2 -maxdepth 2 -name .runner 2>/dev/null) || true
  [[ -n $old ]] || return 0
  [[ $old != *$'\n'* ]] ||
    die "Several runners are in $DIR/*/. Move the one to keep to $DIR, remove the others under Settings > Actions > Runners, then re-run."
  old=${old%/.runner}
  log "Moving the runner in $old to $DIR"
  if as_root test -e "$old/.service"; then (cd "$old" && as_root ./svc.sh uninstall >/dev/null) || true; fi
  as_root mv "$old" "$DIR.new"
  as_root rm -rf "$DIR"
  as_root mv "$DIR.new" "$DIR"
  if systemd_running; then svc install "$RUNNER_USER" && svc start; fi
}

# The latest release, checked against GitHub's published checksum. A connected
# runner updates itself; one that isn't yet is refreshed here on every run.
download_runner() {
  local arch release tag file sum tmp installed
  if has .runner; then return 0; fi
  case $(dpkg --print-architecture) in
    amd64) arch=x64 ;;
    arm64) arch=arm64 ;;
    armhf) arch=arm ;;
    *)     die "GitHub's runner isn't built for $(dpkg --print-architecture)." ;;
  esac
  # Before sign-in (bootstrap), GitHub's API answers without a login too.
  release=$(gh api repos/actions/runner/releases/latest 2>/dev/null ||
    curl -fsSL https://api.github.com/repos/actions/runner/releases/latest) ||
    die "Couldn't reach GitHub for the runner's latest release."
  tag=$(jq -r .tag_name <<<"$release")
  if has config.sh; then
    installed=$(as_runner ./bin/Runner.Listener --version 2>/dev/null) || true
    if [[ $installed == "${tag#v}" ]]; then
      echo "  runner $installed, not connected to a repo yet"
      return 0
    fi
  fi
  file="actions-runner-linux-$arch-${tag#v}.tar.gz"
  sum=$(jq -r --arg f "$file" '.assets[] | select(.name == $f) | .digest' <<<"$release")
  [[ $sum == sha256:* ]] || die "GitHub lists no checksum for $file; not installing it."
  tmp=$(mktemp)
  curl -fsSL "https://github.com/actions/runner/releases/download/$tag/$file" -o "$tmp"
  echo "${sum#sha256:}  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; die "$file doesn't match its checksum."; }
  as_root rm -rf "$DIR"
  as_root install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$DIR"
  as_root tar -xzf "$tmp" -C "$DIR"
  as_root chown -R "$RUNNER_USER:$RUNNER_USER" "$DIR"
  rm -f "$tmp"
  # The libraries it needs: ICU, Kerberos, OpenSSL, LTTng.
  (cd "$DIR" && as_root ./bin/installdependencies.sh >/dev/null) ||
    warn "Some of the runner's libraries didn't install; connecting names what's missing."
  echo "  runner ${tag#v} installed, not connected to a repo yet"
}

prepare_runner() {
  log "GitHub Actions runner in $DIR, run by user $RUNNER_USER"
  runner_user
  if [[ $DIR == "$MAIN" ]]; then move_old_layout; fi
  download_runner
  # New group memberships reach running runners only after a restart.
  if ((RESTART)) && systemd_running; then
    as_root systemctl try-restart 'actions.runner.*' 2>/dev/null || true
  fi
}

# The folder for $PROJECT's runner: the one already connected to it, else the
# first runner's while it's free, else a new one named after the repo.
pick_dir() {
  local d
  runner_dirs
  for d in "${DIRS[@]}"; do
    use_dir "$d"
    if [[ $(lower "$(connected_repo)") == "$(lower "$PROJECT")" ]]; then return 0; fi
  done
  use_dir "$MAIN"
  [[ -n $(connected_repo) ]] || return 0
  log "The runner in $MAIN serves $(connected_repo), so $PROJECT gets a runner of its own"
  use_dir "$MAIN-${PROJECT/\//-}"
  [[ -z $(connected_repo) ]] ||
    die "$DIR serves $(connected_repo), not $PROJECT. Remove it (runner.sh --remove --project $(connected_repo)), then re-run."
}

connect_runner() {
  if has .runner; then
    runner_name
    [[ -z $(runner_status) ]] || return 0
    warn "Runner $NAME was removed on GitHub; connecting it again."
    stop_runner
    as_root rm -f "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams"
  fi
  log "Connecting runner $NAME to $PROJECT"
  local token
  # The token expires within an hour and can only register runners. --replace
  # takes over a runner of the same name left by an earlier install.
  token=$(gh api -X POST "repos/$PROJECT/actions/runners/registration-token" --jq .token)
  as_runner ./config.sh --unattended --replace --url "https://github.com/$PROJECT" \
    --token "$token" --name "$NAME"
}

start_runner() {
  local unit
  if systemd_running; then
    if ! has .service; then
      stop_by_hand
      svc install "$RUNNER_USER"
    else
      unit=$(as_root cat "$DIR/.service")
      as_root systemctl is-active --quiet "$unit" || stop_by_hand
    fi
    svc start
  else
    # Containers without systemd: a tmux session, which ends when the machine restarts.
    if ! as_root tmux has-session -t "$SESSION" 2>/dev/null; then
      stop_by_hand
      as_root tmux new-session -d -s "$SESSION" "$(printf '%q ' "${RUN_AS[@]}" ./run.sh)"
    fi
    warn "No systemd here, so the runner runs in root's tmux session $SESSION. Re-run this after a restart."
  fi
  log "Waiting for the runner to come online"
  for _ in {1..15}; do
    [[ $(runner_status) != online ]] || return 0
    sleep 2
  done
  warn "Runner $NAME isn't online yet. Check: ~/dev-baseline/machine/runner.sh --status"
}

# One connected runner; non-zero unless GitHub sees it online.
report_runner() {
  local github how logs="$DIR/_diag/"
  runner_name
  gh auth status >/dev/null 2>&1 || die "Sign in to GitHub first: ~/dev-baseline/machine/login.sh"
  github=$(gh api --paginate "$(scope)/actions/runners" --jq ".runners[] | select(.name == \"$NAME\")
    | .status + (if .busy then \", running a job\" else \"\" end)" 2>/dev/null) ||
    github="unknown: this GitHub login can't list the runners of $PROJECT (that needs admin rights)"
  if has .service; then
    how=$(as_root cat "$DIR/.service")
    logs="journalctl -u $how, and $logs"
    how="service $how: $(systemctl is-active "$how" 2>/dev/null || true)"
  elif as_root tmux has-session -t "$SESSION" 2>/dev/null; then
    how="root's tmux session $SESSION (no systemd here)"
  elif started_by_hand; then
    how="started by hand, not a service: run ~/dev-baseline/machine/runner.sh --project $PROJECT to make it one"
  else
    how="not running: run ~/dev-baseline/machine/runner.sh --project $PROJECT to start it"
  fi
  cat <<EOF
Runner $NAME for $PROJECT
  GitHub   ${github:-not registered}
  Runs     as $RUNNER_USER, $how
  Folder   $DIR
  Logs     $logs
EOF
  [[ $github == online* ]]
}

# Every runner here, or the one for --project. Non-zero unless there's at
# least one and GitHub sees each of them online.
show_status() {
  local want=$PROJECT d installed=0 shown=0 connected=0 offline=0
  runner_dirs
  for d in "${DIRS[@]}"; do
    use_dir "$d"
    has config.sh || continue
    installed=1
    PROJECT=$(connected_repo)
    if [[ -n $want && $(lower "$PROJECT") != "$(lower "$want")" ]]; then continue; fi
    ((shown == 0)) || echo
    shown=1
    if [[ -z $PROJECT ]]; then
      echo "Runner in $DIR: installed and ready, not connected to a repo."
      continue
    fi
    connected=$((connected + 1))
    report_runner || offline=$((offline + 1))
  done
  ((installed)) || die "No runner installed in $MAIN. Install it: ~/dev-baseline/machine/runner.sh --prepare"
  if ((connected == 0)); then
    [[ -z $want ]] || echo "No runner here serves $want."
    echo "Connect one: ~/dev-baseline/machine/runner.sh --project ${want:-OWNER/REPO}"
    return 1
  fi
  ((offline == 0))
}

# Unregister a runner. The first runner stays installed, ready to connect
# again; a further repo's runner goes, folder and all.
remove_runner() {
  local want=$PROJECT d token served=()
  runner_dirs
  for d in "${DIRS[@]}"; do
    use_dir "$d"
    PROJECT=$(connected_repo)
    [[ -n $PROJECT ]] || continue
    if [[ -z $want || $(lower "$PROJECT") == "$(lower "$want")" ]]; then served+=("$d"); fi
  done
  if ((${#served[@]} == 0)); then
    echo "No runner here is connected to ${want:-a repo}; nothing to remove."
    return 0
  fi
  ((${#served[@]} == 1)) ||
    die "Several runners here; pick one: ~/dev-baseline/machine/runner.sh --remove --project OWNER/REPO (--status lists them)"
  use_dir "${served[0]}"
  PROJECT=$(connected_repo)
  runner_name
  need_github
  log "Disconnecting runner $NAME from $PROJECT"
  stop_runner
  token=$(gh api -X POST "$(scope)/actions/runners/remove-token" --jq .token)
  if ! as_runner ./config.sh remove --token "$token"; then
    warn "Couldn't unregister it on GitHub; delete $NAME under Settings > Actions > Runners."
    as_root rm -f "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams"
  fi
  if [[ $PROJECT == */* && $(gh api "repos/$PROJECT/actions/runners" --jq .total_count) == 0 ]]; then
    gh variable delete RUNS_ON --repo "$PROJECT" >/dev/null 2>&1 || true
    echo "No runners left for $PROJECT, so its jobs run on GitHub's machines again."
  fi
  if [[ $DIR == "$MAIN" ]]; then
    echo "The runner stays installed in $DIR. Connect it again: ~/dev-baseline/machine/runner.sh --project OWNER/REPO"
  else
    as_root rm -rf "$DIR"
    echo "Deleted its folder, $DIR."
  fi
}

case $MODE in
  prepare) prepare_runner; exit 0 ;;
  status)  show_status; exit ;;
  remove)  remove_runner; exit 0 ;;
esac

[[ -n $PROJECT ]] || PROJECT=$(cat "$STATE/project" 2>/dev/null || true)
[[ -n $PROJECT ]] || die "No project set: run with --project OWNER/REPO"
[[ $PROJECT =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--project must look like OWNER/REPO (got: $PROJECT)"
pick_dir
current=$(connected_repo)
need_github
[[ -n $current ]] || check_public
prepare_runner
connect_runner
start_runner
log "Sending the project's jobs here: repo variable RUNS_ON=self-hosted"
gh variable set RUNS_ON --body self-hosted --repo "$PROJECT"

cat <<EOF

Runner $NAME works for $PROJECT (GitHub: Settings > Actions > Runners).
  Jobs   The project template's workflows run here while RUNS_ON is set.
         Other workflows: put runs-on: self-hosted on the jobs that should.
  Runs   as user $RUNNER_USER, from $DIR
  Check  ~/dev-baseline/machine/runner.sh --status     (every runner here: online? service? logs?)
  Undo   gh variable delete RUNS_ON --repo $PROJECT   (jobs back to GitHub's machines)
         ~/dev-baseline/machine/runner.sh --remove --project $PROJECT   (disconnect it)
EOF
