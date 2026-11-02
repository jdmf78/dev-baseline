## This machine

It was set up with dev-baseline, whose scripts are in `~/dev-baseline`. Use
them for machine setup, so every machine running the kit works the same way.

### GitHub Actions runners

This is a development machine, and self-hosted runners never run here. They
run on servers of their own, which the user sets up with
`~/dev-baseline/docs/runner.md`.

- Never install, connect or start a runner on this machine: no `config.sh`,
  `run.sh` or `svc.sh`, no download from actions/runner, no `runner` user,
  never `RUNNER_ALLOW_RUNASROOT`. If the user wants jobs on their own
  hardware, point them to that guide, for a server other than this one.
- If you find a runner here (`/home/runner`, or
  `systemctl list-units 'actions.runner.*'`), leave it running and tell the
  user: an older dev-baseline installed it, and the guide's "Take runners off
  a machine" removes it.
- Jobs reach a runner server with `runs-on: self-hosted`. Workflows from the
  dev-baseline project template read the repo variable `RUNS_ON` instead.
  Once the repo has a runner online
  (`gh api repos/OWNER/REPO/actions/runners --jq '.runners[].status'`),
  `gh variable set RUNS_ON --body self-hosted` sends its jobs there, and
  `gh variable delete RUNS_ON` sends them back to GitHub's machines.
- Self-hosted runners belong on private repos; using one for a public repo is
  the user's call.
