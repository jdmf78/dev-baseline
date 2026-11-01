# GitHub Actions runner, by hand

This sets up a self-hosted runner for one repository on Ubuntu: a `runner`
user, the runner in `/home/runner/actions-runner`, connected to your
repository and running as a service under `runner` that starts at boot. The
same machine can run jobs for more repositories later; see
[More repositories](#more-repositories).

Run every command as root, in one shell, from top to bottom. GitHub's runner
refuses to run as root ("Must not run with sudo"), so the commands hand the
steps that need it to the `runner` user.

On a machine set up with dev-baseline, one command does all of this for the
first repository: `~/dev-baseline/machine/runner.sh --project YOUR_USERNAME/YOUR_PROJECT`.
The steps below end in the same layout, so `runner.sh --status` and
`--remove` also work on a runner set up by hand.

## 1. Fill in your repository and token

Replace both placeholders, then paste:

```bash
REPO=YOUR_USERNAME/YOUR_PROJECT
TOKEN=YOUR_RUNNER_TOKEN
DIR=/home/runner/actions-runner
```

- `REPO` is the repository as in its address: `github.com/octocat/invoice-api`
  becomes `octocat/invoice-api`.
- `TOKEN` is the registration token from the repository on GitHub: Settings >
  Actions > Runners > New self-hosted runner, in the line
  `./config.sh --url ... --token ...`. It works for one hour, for that
  repository only, and is needed only to connect. Never commit it. With `gh`
  signed in as an admin of the repository, this gets one instead:
  `TOKEN=$(gh api -X POST repos/$REPO/actions/runners/registration-token --jq .token)`
- `DIR` is the runner's folder. Keep it as it is for the first repository on
  the machine.

## 2. Create the runner user

```bash
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
```

Lets jobs use Docker. It only does something when Docker is installed: without
Docker there's no `docker` group, and nothing to add.

```bash
getent group docker >/dev/null && usermod -aG docker runner
```

Passwordless sudo, as on GitHub's own runners, for jobs that run
`sudo apt-get install` and the like. dev-baseline's `runner.sh` does the same;
skip it if your jobs never need root. If `sudo` is missing, first run
`apt update && apt install -y sudo`.

```bash
echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner
```

Docker access and sudo each make `runner` as powerful as root, so give each
project its own machine or container.

## 3. Download the runner

Skip this step if `$DIR/config.sh` already exists; dev-baseline installs the
first runner in `/home/runner/actions-runner`.

```bash
VERSION=2.338.0
SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
```

```bash
mkdir -p "$DIR" && cd "$DIR"
curl -fLo runner.tar.gz https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-linux-x64-$VERSION.tar.gz
echo "$SHA256  runner.tar.gz" | sha256sum -c && tar xzf runner.tar.gz && rm runner.tar.gz
./bin/installdependencies.sh
chown -R runner:runner "$DIR"
```

The version and checksum are for x64 machines. For ARM, or a newer version,
take both from GitHub's New self-hosted runner page (pick Linux and the
architecture), and replace `x64` with `arm64` in the address. Once connected,
the runner keeps itself up to date.

## 4. Connect it to your repository

Runs `config.sh` as `runner`:

```bash
runuser -l runner -c "cd $DIR && ./config.sh --unattended --replace --url https://github.com/$REPO --token $TOKEN"
```

`--unattended` takes the defaults that GitHub's page asks about: the machine's
hostname as the runner's name, the labels `self-hosted`, `Linux` and `X64`,
and the work folder `_work`. `--replace` takes over an older runner of the
same name in the same repository.

## 5. Run it as a service

Stop a `./run.sh` you started by hand earlier (Ctrl-C) first. This installs a
systemd service that runs as `runner` and starts at boot, then starts it now:

```bash
cd "$DIR" && ./svc.sh install runner && ./svc.sh start
```

`svc.sh` only exists once step 4 has run.

## 6. Check it

```bash
cd "$DIR" && ./svc.sh status
```

The repository's Settings > Actions > Runners now lists it as Idle. To follow
its log:

```bash
journalctl -u "$(cat "$DIR/.service")" -f
```

If you install Docker later, repeat the `docker` group step in 2, then
restart every runner on the machine so they pick up the group:

```bash
systemctl restart 'actions.runner.*'
```

## Use it in a workflow

```yaml
runs-on: self-hosted
```

Projects from dev-baseline's template read `runs-on` from the repository
variable `RUNS_ON` instead, so set that:

```bash
gh variable set RUNS_ON --body self-hosted --repo "$REPO"
```

## More repositories

A runner belongs to one repository, but one machine can run a runner for each
of your repositories:

- Each runner has its own folder, its own token from its own repository, and
  its own service, `actions.runner.OWNER-REPO.NAME`. They all run as the same
  `runner` user and start at boot.
- The token is needed once, to connect. A connected runner keeps its own
  credentials and keeps working after the token expires.
- Each runner takes one job at a time. Runners on one machine run their jobs
  in parallel and share its CPU, memory, disk and Docker. Each repository
  only sends jobs to its own runners.
- They're independent: stopping, updating or removing one leaves the others
  alone.

To add a repository, set its values in a root shell. The folder is named
after the repository, so every machine names it the same way:

```bash
REPO=YOUR_USERNAME/OTHER_PROJECT
TOKEN=ITS_RUNNER_TOKEN
DIR=/home/runner/actions-runner-${REPO/\//-}
```

Then run steps 3 to 6 again; the `runner` user from step 2 is already there.
Set `RUNS_ON` for that repository too. To see every runner on the machine:

```bash
systemctl list-units 'actions.runner.*'
```

dev-baseline's `runner.sh` manages only the runner in
`/home/runner/actions-runner`. Manage the others with the commands here, after
setting `DIR` to their folder.

### One runner for many repositories

Only an organization's repositories can share a runner; a personal account
has no runners for all its repositories. A free organization is enough:
create one, move repositories into it (repository Settings > Transfer), then
connect a runner to the organization instead of a repository:

```bash
REPO=YOUR_ORGANIZATION
TOKEN=ITS_RUNNER_TOKEN
DIR=/home/runner/actions-runner-${REPO/\//-}
```

The token comes from the organization's Settings > Actions > Runners > New
runner > New self-hosted runner, or from
`gh api -X POST orgs/$REPO/actions/runners/registration-token --jq .token`.
Steps 3 to 6 stay the same. All of the organization's private repositories
can use it; public ones only after you allow them in its Settings > Actions >
Runner groups, which GitHub advises against. It still takes one job at a
time: for more at once, add another runner for the organization in its own
folder and with its own name, by adding `--name $(hostname -s)-2` to step 4.
With the same name, `--replace` would take over the first one.

## Remove it

Get a removal token from the same GitHub page (Settings > Actions > Runners,
the runner, Remove). With `DIR` set to the runner's folder, replace the
placeholder, then paste:

```bash
REMOVE_TOKEN=YOUR_REMOVAL_TOKEN
```

```bash
cd "$DIR" && ./svc.sh stop && ./svc.sh uninstall
runuser -l runner -c "cd $DIR && ./config.sh remove --token $REMOVE_TOKEN"
```

The runner stays installed, ready to connect again from step 1. Delete the
folder of a runner you added for another repository with `rm -rf "$DIR"`.

## When something fails

- "Must not run with sudo": `config.sh` or `run.sh` ran as root. Run them
  through `runuser -l runner -c "..."` as above.
  `export RUNNER_ALLOW_RUNASROOT=1` lets them run as root, but then every job
  runs as root too.
- "Cannot configure the runner because it is already configured": the folder
  in `DIR` is connected already. Remove it first, or pick the folder for a
  new repository (see More repositories).
- "error: exists /etc/systemd/system/actions.runner...": the service is
  installed already. `./svc.sh uninstall`, then step 5 again.
- A 404 or "Invalid token" during step 4: the token expired after an hour or
  belongs to another repository. Get a new one.
