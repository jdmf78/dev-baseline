#!/usr/bin/env bash
# One command to set up a development server or container: system, tools and
# AI coding CLIs (machine/bootstrap.sh), then sign-in to GitHub and each AI
# CLI, plus your project (machine/login.sh). Works as root or with sudo. Safe
# to re-run. It never sets up a GitHub Actions runner: those run on servers of
# their own (docs/runner.md).
#
# Usage: ./install.sh --project OWNER/REPO [--agents LIST] [--domain NAME]
#                     [--harden] [--web] [--no-docker] [--git-name NAME] [--git-email EMAIL]
#   --project OWNER/REPO   the GitHub repo you develop in, cloned to ~/code/REPO
#                          (created as a private repo, if you agree, when missing)
#   --agents LIST          AI coding CLIs, comma-separated: claude, codex, opencode
#                          (default: all three; a re-run keeps the previous choice)
#   Other options go to machine/bootstrap.sh; see machine/bootstrap.sh --help.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=()
for arg in "$@"; do
  case $arg in
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0 ;;
    --runner)
      echo "Ignoring --runner: runners don't run on development machines. Set one up on" >&2
      echo "a server of its own: ~/dev-baseline/docs/runner.md" >&2 ;;
    *) args+=("$arg") ;;
  esac
done

"$HERE/machine/bootstrap.sh" "${args[@]}"
"$HERE/machine/login.sh"

# Hand over a fresh shell, so PATH, mise and the `dev` command are live.
if [[ -t 0 && -t 1 ]]; then
  echo
  echo "Opening a fresh shell. Type: dev"
  exec bash -l
fi
