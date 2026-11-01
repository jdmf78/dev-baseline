## This machine

It was set up with dev-baseline, whose scripts are in `~/dev-baseline`. Use
them for machine setup, so every machine running the kit works the same way.

### GitHub Actions runners

Every machine set up with the kit has a self-hosted runner installed in
`/home/runner/actions-runner`, run by the user `runner` (never root, never
`RUNNER_ALLOW_RUNASROOT`). It may not be connected to a repo yet. A runner
serves one repo, so each further repo gets a runner of its own next to it, in
`/home/runner/actions-runner-OWNER-REPO`, with its own systemd service.
Manage them only with `~/dev-baseline/machine/runner.sh`:

- `--status`: start here. Lists every runner here with its repo, whether it's
  online or busy, how it runs and where its logs are; exits non-zero unless
  each is online. `--status --project OWNER/REPO` shows just that repo's.
- `--project OWNER/REPO` (default: this machine's project): connects a
  runner to that repo, in the first runner's folder while it's free, else in
  a folder of its own, and runs it as a systemd service that survives
  reboots. Safe to repeat; it repairs what's missing and takes over a
  `./run.sh` started by hand.
- `--remove --project OWNER/REPO`: disconnects that repo's runner. The first
  runner stays installed and ready; a further repo's runner is deleted.
- Logs: `journalctl -u 'actions.runner.*'`, plus `_diag/` in each folder.
- Jobs reach a repo's runner with `runs-on: self-hosted`. Workflows from the
  dev-baseline project template read the repo variable `RUNS_ON` instead,
  which connecting sets.
- Each runner takes one job at a time, and all of them share this machine.
- Don't run `config.sh`, `run.sh` or `svc.sh` yourself, and don't install
  runners anywhere else. Self-hosted runners belong on private repos;
  connecting one to a public repo is the user's call.
