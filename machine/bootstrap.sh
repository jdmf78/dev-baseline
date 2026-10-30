#!/usr/bin/env bash
# Idempotent bootstrap for an Ubuntu (24.04+) dev server or container that runs
# Claude Code and Codex. Run as root (the default in LXC containers) or as a
# user with sudo. Safe to re-run: every step skips work that is already done.
#
# Usage: ./bootstrap.sh [options]
#   --project OWNER/REPO  your development repo; login.sh clones it to ~/code/REPO
#   --git-name NAME       git user.name (default: your GitHub username, set by login.sh)
#   --git-email EMAIL     git user.email (default: your private GitHub noreply address)
#   --harden              key-only SSH, ufw firewall (deny inbound), fail2ban
#   --web                 allow 80/443 inbound (to receive webhooks on this box)
#   --no-docker           skip Docker Engine
#   -h, --help            show this help
set -euo pipefail

FILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
STATE="$HOME/.config/dev-baseline"
MARK_BEGIN="# >>> dev-baseline >>>"
MARK_END="# <<< dev-baseline <<<"
PROJECT="" GIT_NAME="" GIT_EMAIL="" HARDEN=0 WEB=0 DOCKER=1 APT_UPDATED=0
USER=${USER:-$(id -un)} # containers often leave USER unset for root

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
# Run a command with root rights: directly as root, through sudo otherwise.
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
# Containers without systemd (e.g. plain Docker) can't manage services.
systemd_running() { [[ -d /run/systemd/system ]]; }

while (($#)); do
  case $1 in
    --project)   PROJECT=${2:?--project needs OWNER/REPO}; shift 2 ;;
    --git-name)  GIT_NAME=${2:?--git-name needs a value}; shift 2 ;;
    --git-email) GIT_EMAIL=${2:?--git-email needs a value}; shift 2 ;;
    --harden)    HARDEN=1; shift ;;
    --web)       WEB=1; shift ;;
    --no-docker) DOCKER=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown option: $1" ;;
  esac
done
if [[ -n $PROJECT && ! $PROJECT =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  die "--project must look like OWNER/REPO (got: $PROJECT)"
fi

apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  ((${#missing[@]})) || return 0
  if ((!APT_UPDATED)); then as_root apt-get update -qq; APT_UPDATED=1; fi
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

restart_service() {
  if systemd_running; then
    as_root systemctl restart "$1" || warn "Could not restart $1."
  else
    warn "systemd isn't running here; start $1 yourself."
  fi
}

# Copy a default config into place unless the user already has one.
install_if_absent() {
  if [[ ! -e $2 ]]; then
    install -m "${3:-0644}" "$1" "$2"
  elif ! cmp -s "$1" "$2"; then
    warn "$2 exists; left as-is (defaults are in $1)."
  fi
}

# Replace (or append) the dev-baseline block in a shell startup file.
write_block() {
  local file=$1 body=$2 tmp
  tmp=$(mktemp)
  if [[ -f $file ]]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$file" >"$tmp"
  fi
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >>"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

preflight() {
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die "This script targets Ubuntu (found: ${ID:-unknown})."
  dpkg --compare-versions "$VERSION_ID" ge 24.04 || die "Ubuntu 24.04+ required (found $VERSION_ID)."
  CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
  ARCH=$(dpkg --print-architecture)
  if ((EUID != 0)); then
    have sudo || die "Run as root, or as a user with sudo."
    sudo -v || die "sudo access is required."
  fi
  mkdir -p "$HOME/.local/bin" "$HOME/.config/git"
}

base_packages() {
  log "Base packages"
  # bubblewrap + socat back the Claude Code and Codex command sandboxes on Linux.
  apt_install build-essential ca-certificates curl wget gnupg git git-lfs unzip zip \
    jq ripgrep fd-find tmux screen htop tree direnv shellcheck openssl openssh-client \
    bubblewrap socat unattended-upgrades
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' |
      as_root tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  fi
}

github_cli() {
  log "GitHub CLI (from GitHub's apt repo; Ubuntu's own package lags behind)"
  local list=/etc/apt/sources.list.d/github-cli.list
  if [[ ! -f $list ]]; then
    as_root install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
      as_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
      as_root tee "$list" >/dev/null
    APT_UPDATED=0
  fi
  if ((!APT_UPDATED)); then as_root apt-get update -qq; APT_UPDATED=1; fi
  # Installs gh, or upgrades an older Ubuntu build to GitHub's current release.
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
}

mise_tools() {
  if ! have mise; then
    log "mise (runtime and tool version manager)"
    as_root install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor |
      as_root tee /etc/apt/keyrings/mise-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$ARCH] https://mise.jdx.dev/deb stable main" |
      as_root tee /etc/apt/sources.list.d/mise.list >/dev/null
    APT_UPDATED=0
    apt_install mise
  fi
  # "latest" is re-resolved on every run, so re-running bootstrap upgrades Python.
  # Ubuntu's own python3 stays in place for system tools.
  log "Global tools via mise: latest Python, Node 24, just, actionlint, gitleaks"
  mise use --global --yes python@latest node@24 just@latest actionlint@latest gitleaks@latest
  echo "  $(mise exec -- python --version)"
}

docker_engine() {
  ((DOCKER)) || return 0
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if ! have docker; then
    log "Docker Engine"
    as_root install -d -m 0755 /etc/apt/keyrings
    as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    as_root chmod a+r /etc/apt/keyrings/docker.asc
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" |
      as_root tee /etc/apt/sources.list.d/docker.sources >/dev/null
    APT_UPDATED=0
    if ! apt_install "${pkgs[@]}"; then
      # Usually an LXC container without nesting: the daemon can't start, and a
      # half-configured package would break every later apt step. Roll it back.
      as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkgs[@]}" || true
      warn "Docker could not be installed here. In LXC, enable nesting and keyctl"
      warn "(Proxmox: Options > Features), restart the container and re-run, or use --no-docker."
      return 0
    fi
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    # Rotate container logs so a chatty service can't fill the disk.
    echo '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }' |
      as_root tee /etc/docker/daemon.json >/dev/null
    restart_service docker
  fi
  if ((EUID != 0)) && ! id -nG "$USER" | grep -qw docker; then
    as_root usermod -aG docker "$USER"
    warn "Added $USER to the docker group (root-equivalent, agents included). Log out and in to apply."
  fi
  as_root docker info >/dev/null 2>&1 ||
    warn "Docker is installed but its daemon isn't running. In LXC, enable nesting and keyctl."
}

git_config() {
  log "Git defaults"
  if [[ -n $GIT_NAME ]]; then git config --global user.name "$GIT_NAME"; fi
  if [[ -n $GIT_EMAIL ]]; then git config --global user.email "$GIT_EMAIL"; fi
  local kv
  for kv in init.defaultBranch=main pull.rebase=true rebase.autoStash=true \
    push.autoSetupRemote=true fetch.prune=true rerere.enabled=true \
    diff.algorithm=histogram merge.conflictStyle=zdiff3; do
    git config --global "${kv%%=*}" "${kv#*=}"
  done
  install_if_absent "$FILES/gitignore_global" "$HOME/.config/git/ignore"
}

ssh_key() {
  log "Per-machine SSH key for GitHub"
  local key="$HOME/.ssh/github_ed25519" email line
  install -d -m 0700 "$HOME/.ssh"
  if [[ ! -f $key ]]; then
    # One key per machine, so a compromised box can be revoked on its own.
    ssh-keygen -q -t ed25519 -N "" -C "$USER@$(hostname -s) github" -f "$key"
  fi
  if ! grep -qs '^Host github.com' "$HOME/.ssh/config"; then
    printf '\nHost github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$key" >>"$HOME/.ssh/config"
    chmod 0600 "$HOME/.ssh/config"
  fi
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    # Pin GitHub's published host keys instead of trusting on first use.
    curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' >>"$HOME/.ssh/known_hosts"
  fi

  # Sign commits with the same key. GitHub marks them Verified when the commit
  # email belongs to the account, which the noreply address from login.sh does.
  git config --global gpg.format ssh
  git config --global user.signingkey "$key.pub"
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  git config --global gpg.ssh.allowedSignersFile "$HOME/.config/git/allowed_signers"
  email=$(git config --global user.email || true)
  if [[ -n $email ]]; then
    line="$email namespaces=\"git\" $(cut -d' ' -f1,2 "$key.pub")"
    grep -qxF "$line" "$HOME/.config/git/allowed_signers" 2>/dev/null ||
      echo "$line" >>"$HOME/.config/git/allowed_signers"
  fi
}

# shellcheck disable=SC2016 # blocks are written literally and expand at shell startup
shell_config() {
  log "Shell startup files"
  # ~/.profile: login and non-interactive shells (ssh host cmd, cron) see mise tools.
  # Projects in ~/code (and the agents' worktrees inside them) are trusted by mise,
  # so a fresh worktree can run `just check` without a trust prompt.
  write_block "$HOME/.profile" 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export MISE_TRUSTED_CONFIG_PATHS="$HOME/code"'
  write_block "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"
export MISE_TRUSTED_CONFIG_PATHS="$HOME/code"
eval "$(mise activate bash)"
eval "$(direnv hook bash)"
# `dev`: a tmux session in your project that survives SSH drops. Run claude/codex in it.
unalias dev 2>/dev/null || true
dev() { tmux new-session -A -s dev -c "$(cat ~/.config/dev-baseline/project-dir 2>/dev/null || echo ~)"; }'
  install_if_absent "$FILES/tmux.conf" "$HOME/.tmux.conf"
}

ai_tools() {
  log "Claude Code and Codex CLIs (installed, or updated to the latest release)"
  local claude_bin
  claude_bin=$(command -v claude || echo "$HOME/.local/bin/claude")
  if [[ -x $claude_bin ]]; then
    "$claude_bin" update >/dev/null 2>&1 || warn "claude update failed; keeping the installed version."
  else
    curl -fsSL https://claude.ai/install.sh | bash
    claude_bin="$HOME/.local/bin/claude"
  fi
  # Codex is an npm package; mise supplies its Node and upgrades it on every run.
  mise use --global --yes npm:@openai/codex@latest
  echo "  claude $("$claude_bin" --version 2>/dev/null || echo 'not found')"
  echo "  $(mise exec -- codex --version 2>/dev/null || echo 'codex not found')"
  install -d -m 0700 "$HOME/.claude" "$HOME/.codex"
  install_if_absent "$FILES/claude-settings.json" "$HOME/.claude/settings.json"
  install_if_absent "$FILES/codex-config.toml" "$HOME/.codex/config.toml"
}

harden_ssh() {
  ((HARDEN)) || return 0
  log "SSH: key-only login"
  if [[ ! -x /usr/sbin/sshd ]]; then
    warn "No SSH server installed (common in containers you enter with lxc exec or pct enter); skipping."
    return 0
  fi
  if [[ ! -s $HOME/.ssh/authorized_keys ]]; then
    warn "$HOME/.ssh/authorized_keys is empty: leaving password login on so you aren't locked out."
    warn "Add your laptop's public key there and re-run with --harden."
    return 0
  fi
  # Logged in as root (typical for containers): keep root, but only with a key.
  local root_login=no conf=/etc/ssh/sshd_config.d/10-dev-baseline.conf
  if ((EUID == 0)); then root_login=prohibit-password; fi
  printf '%s\n' \
    "# Managed by dev-baseline. Sorts before 50-cloud-init.conf; sshd keeps the first value it reads." \
    "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin $root_login" \
    "MaxAuthTries 3" "X11Forwarding no" | as_root tee "$conf" >/dev/null
  as_root install -d -m 0755 /run/sshd
  if ! as_root /usr/sbin/sshd -t; then
    as_root rm -f "$conf"
    die "sshd rejected the config; removed $conf and left SSH unchanged."
  fi
  if systemd_running; then
    as_root systemctl try-reload-or-restart ssh
  else
    warn "systemd isn't running: restart sshd yourself to apply $conf."
  fi
  apt_install fail2ban
  if systemd_running; then
    as_root systemctl enable --now fail2ban >/dev/null 2>&1 ||
      warn "fail2ban didn't start (it needs iptables, which some containers lack)."
  fi
}

firewall() {
  ((HARDEN || WEB)) || return 0
  log "Firewall (ufw)"
  apt_install ufw
  local ports=() port
  if [[ -x /usr/sbin/sshd ]]; then
    mapfile -t ports < <(as_root /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
  fi
  ((${#ports[@]})) || ports=(22)
  for port in "${ports[@]}"; do as_root ufw allow "$port/tcp" comment ssh >/dev/null; done
  if ((WEB)); then
    as_root ufw allow 80/tcp comment http >/dev/null
    as_root ufw allow 443/tcp comment https >/dev/null
    as_root ufw allow 443/udp comment http3 >/dev/null
  fi
  if ((HARDEN)); then
    as_root ufw default deny incoming >/dev/null
    as_root ufw default allow outgoing >/dev/null
    as_root ufw --force enable >/dev/null 2>&1 ||
      warn "ufw couldn't start (usual in unprivileged containers): firewall at the host instead."
  fi
  warn "Docker-published ports bypass ufw. Bind app ports to 127.0.0.1 and publish only the proxy."
}

record_project() {
  [[ -n $PROJECT ]] || return 0
  mkdir -p "$STATE"
  echo "$PROJECT" >"$STATE/project"
  log "Project $PROJECT recorded; login.sh clones it once GitHub is signed in."
}

summary() {
  cat <<'EOF'

Bootstrap complete. Next (install.sh does this for you):
  machine/login.sh   sign in to GitHub, Codex and Claude Code, then set up your project.
Afterwards, open a new shell (log out and back in) so the shell changes apply.
EOF
}

preflight
base_packages
github_cli
mise_tools
docker_engine
git_config
ssh_key
shell_config
ai_tools
record_project
harden_ssh
firewall
summary
