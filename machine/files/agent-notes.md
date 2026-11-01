## This machine

It was set up with dev-baseline, whose scripts are in `~/dev-baseline`. Use
them for machine setup, so every machine running the kit works the same way.

### GitHub Actions runner

Every machine set up with the kit has a self-hosted runner installed in
`/home/runner/actions-runner`, run by the user `runner` (never root, never
`RUNNER_ALLOW_RUNASROOT`). It may not be connected to a repo yet. Manage it
only with `~/dev-baseline/machine/runner.sh`:

- `--status`: start here. Shows its repo, whether it's online or busy, how it
  runs and where its logs are; exits non-zero unless it's online.
- `--project OWNER/REPO` (default: this machine's project): connects it to
  that repo and runs it as a systemd service that survives reboots. Safe to
  repeat; it repairs what's missing and takes over a `./run.sh` started by hand.
- `--remove`: disconnects it from its repo; it stays installed and ready.
- One runner serves one repo. To switch, `--remove`, then connect again.
- Runners for further repos (or an organization) may run next to it, in
  `/home/runner/actions-runner-OWNER-REPO`, each its own service; the user
  adds them with `~/dev-baseline/docs/runner.md`.
  `systemctl list-units 'actions.runner.*'` lists every runner here.
- Logs: `journalctl -u 'actions.runner.*'`, plus `_diag/` in its folder.
- Jobs reach it with `runs-on: self-hosted`. Workflows from the dev-baseline
  project template read the repo variable `RUNS_ON` instead, which
  connecting sets.
- Don't run `config.sh`, `run.sh` or `svc.sh` yourself, and don't add
  runners yourself; when another repo needs one, point the user to that
  guide. Self-hosted runners belong on private repos; connecting one to a
  public repo is the user's call.
