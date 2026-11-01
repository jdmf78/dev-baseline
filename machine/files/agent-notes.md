## This machine

It was set up with dev-baseline, whose scripts are in `~/dev-baseline`. Use
them for machine setup, so every machine running the kit works the same way.

### GitHub Actions runner

A repo's workflow jobs can run on this machine through a self-hosted runner.
Manage it only with `~/dev-baseline/machine/runner.sh --project OWNER/REPO`
(the project defaults to the one this machine was set up for):

- No options: sets the runner up, repairs it, or adopts one already configured
  by hand in `~runner`, and is safe to repeat. The runner always runs as the
  `runner` user, never as root (no `RUNNER_ALLOW_RUNASROOT`), as a systemd
  service that survives reboots. A `./run.sh` started by hand is stopped so
  the service takes over.
- `--status`: online or not, busy or not, how it runs, where the logs are.
- `--remove`: unregisters the runner and deletes it.
- Logs: `journalctl -u 'actions.runner.*'`, plus `_diag/` in its folder.
- Jobs reach it with `runs-on: self-hosted`. Workflows from the dev-baseline
  project template read the repo variable `RUNS_ON` instead, which the script
  sets.
- Don't run `config.sh`, `run.sh` or `svc.sh` yourself. Self-hosted runners
  belong on private repos; adding one to a public repo is the user's call.
