#!/usr/bin/env bash
# Idempotent bootstrap for an Ubuntu (24.04+) dev server that runs Claude Code
# and Codex. Safe to re-run: every step skips work that is already done.
#
# Usage: ./bootstrap.sh [options]
#   --git-name NAME     git user.name (default: your GitHub username, set by login.sh)
#   --git-email EMAIL   git user.email (default: your private GitHub noreply address)
#   --harden            key-only SSH, ufw firewall (deny inbound), fail2ban
#   --web               allow 80/443 inbound (to receive webhooks on this box)
#   --no-docker         skip Docker Engine
#   -h, --help          show this help
set -euo pipefail

FILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
MARK_BEGIN="# >>> dev-baseline >>>"
MARK_END="# <<< dev-baseline <<<"
GIT_NAME="" GIT_EMAIL="" HARDEN=0 WEB=0 DOCKER=1 APT_UPDATED=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    --git-name)  GIT_NAME=${2:?--git-name needs a value}; shift 2 ;;
    --git-email) GIT_EMAIL=${2:?--git-email needs a value}; shift 2 ;;
    --harden)    HARDEN=1; shift ;;
    --web)       WEB=1; shift ;;
    --no-docker) DOCKER=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown option: $1" ;;
  esac
done

apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  ((${#missing[@]})) || return 0
  if ((!APT_UPDATED)); then sudo apt-get update -qq; APT_UPDATED=1; fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
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
  [[ $EUID -ne 0 ]] || die "Run as your normal user (with sudo rights), not as root."
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die "This script targets Ubuntu (found: ${ID:-unknown})."
  dpkg --compare-versions "$VERSION_ID" ge 24.04 || die "Ubuntu 24.04+ required (found $VERSION_ID)."
  CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
  ARCH=$(dpkg --print-architecture)
  sudo -v || die "sudo access is required."
  mkdir -p "$HOME/.local/bin" "$HOME/.config/git"
}

base_packages() {
  log "Base packages"
  # bubblewrap + socat back the Claude Code and Codex command sandboxes on Linux.
  apt_install build-essential ca-certificates curl wget gnupg git git-lfs unzip zip \
    jq ripgrep fd-find tmux htop tree direnv shellcheck openssl \
    bubblewrap socat unattended-upgrades
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' |
      sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  fi
}

github_cli() {
  have gh && return 0
  log "GitHub CLI"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  APT_UPDATED=0
  apt_install gh
}

mise_tools() {
  if ! have mise; then
    log "mise (runtime and tool version manager)"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor |
      sudo tee /etc/apt/keyrings/mise-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$ARCH] https://mise.jdx.dev/deb stable main" |
      sudo tee /etc/apt/sources.list.d/mise.list >/dev/null
    APT_UPDATED=0
    apt_install mise
  fi
  log "Global tools via mise (projects pin their own in mise.toml)"
  mise use --global --yes node@24 just@latest actionlint@latest gitleaks@latest
}

docker_engine() {
  ((DOCKER)) || return 0
  if ! have docker; then
    log "Docker Engine"
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" |
      sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
    APT_UPDATED=0
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    # Rotate container logs so a chatty service can't fill the disk.
    echo '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }' |
      sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl restart docker
  fi
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    warn "Added $USER to the docker group (root-equivalent, agents included). Log out and in to apply."
  fi
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
  write_block "$HOME/.profile" 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"'
  write_block "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"
eval "$(direnv hook bash)"
# Persistent session that survives SSH drops: run claude/codex inside it.
alias dev="tmux new-session -A -s dev"'
  install_if_absent "$FILES/tmux.conf" "$HOME/.tmux.conf"
}

ai_tools() {
  log "Claude Code and Codex"
  if ! have claude && [[ ! -x $HOME/.local/bin/claude ]]; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  if ! have codex; then
    mise use --global --yes npm:@openai/codex@latest
  fi
  install -d -m 0700 "$HOME/.claude" "$HOME/.codex"
  install_if_absent "$FILES/claude-settings.json" "$HOME/.claude/settings.json"
  install_if_absent "$FILES/codex-config.toml" "$HOME/.codex/config.toml"
}

harden_ssh() {
  ((HARDEN)) || return 0
  log "SSH: key-only login, no root"
  [[ -s $HOME/.ssh/authorized_keys ]] ||
    die "$HOME/.ssh/authorized_keys is empty: refusing to disable passwords (you would be locked out)."
  local conf=/etc/ssh/sshd_config.d/10-dev-baseline.conf
  sudo tee "$conf" >/dev/null <<'EOF'
# Managed by dev-baseline. Sorts before 50-cloud-init.conf, and sshd keeps the first value it reads.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
EOF
  sudo install -d -m 0755 /run/sshd
  if ! sudo sshd -t; then
    sudo rm -f "$conf"
    die "sshd rejected the config; removed $conf and left SSH unchanged."
  fi
  sudo systemctl try-reload-or-restart ssh
  apt_install fail2ban
  sudo systemctl enable --now fail2ban >/dev/null
}

firewall() {
  ((HARDEN || WEB)) || return 0
  log "Firewall (ufw)"
  apt_install ufw
  local ports port
  mapfile -t ports < <(sudo sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
  ((${#ports[@]})) || ports=(22)
  for port in "${ports[@]}"; do sudo ufw allow "$port/tcp" comment ssh >/dev/null; done
  if ((WEB)); then
    sudo ufw allow 80/tcp comment http >/dev/null
    sudo ufw allow 443/tcp comment https >/dev/null
    sudo ufw allow 443/udp comment http3 >/dev/null
  fi
  if ((HARDEN)); then
    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    sudo ufw --force enable >/dev/null
  fi
  warn "Docker-published ports bypass ufw. Bind app ports to 127.0.0.1 and publish only the proxy."
}

summary() {
  cat <<'EOF'

Bootstrap complete. Next:
  1. Log out and back in (or run: exec bash -l) so PATH, mise and the docker group apply.
  2. Run machine/login.sh to sign in to GitHub, upload this machine's SSH key,
     and log in to Claude Code and Codex.
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
harden_ssh
firewall
summary
