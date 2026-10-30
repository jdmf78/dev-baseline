#!/usr/bin/env bash
# One command to set up a development server or container: system, tools,
# Claude Code and Codex (machine/bootstrap.sh), then GitHub, Codex and Claude
# Code sign-in plus your project (machine/login.sh). Works as root or with
# sudo. Safe to re-run.
#
# Usage: ./install.sh --project OWNER/REPO [--harden] [--web] [--no-docker]
#                     [--git-name NAME] [--git-email EMAIL]
#   --project OWNER/REPO   the GitHub repo you develop in, cloned to ~/code/REPO
#                          (created as a private repo, if you agree, when missing)
#   Other options go to machine/bootstrap.sh; see machine/bootstrap.sh --help.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for arg in "$@"; do
  if [[ $arg == -h || $arg == --help ]]; then
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
  fi
done

"$HERE/machine/bootstrap.sh" "$@"
"$HERE/machine/login.sh"
