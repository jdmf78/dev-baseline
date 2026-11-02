# GitHub Actions runners, on servers of their own

Self-hosted runners never run on a development machine set up with
dev-baseline. Every job runs with Docker and sudo, so on a development
machine a workflow could reach the agents' sign-ins, keys and code.
dev-baseline doesn't install a runner, and its agents are told not to set one
up. Run them on a server, VM or container of their own instead.

This guide sets up such a server: a `runner` user, the runner in
`/home/runner/actions-runner`, connected to your repository and running as a
service under `runner` that starts at boot. The same server can run jobs for
more repositories later; see [More repositories](#more-repositories).

Run every command on that server as root, in one shell, from top to bottom.
GitHub's runner refuses to run as root ("Must not run with sudo"), so the
commands hand the steps that need it to the `runner` user.

## Before you start

- The server runs Ubuntu, or another Linux that GitHub's runner supports, and
  isn't a development machine.
- It has `curl` (`apt update && apt install -y curl`), and `sudo` if your jobs
  need root (`apt install -y sudo`).
- If jobs use Docker (`docker build`, `docker compose`, or `container:` and
  `services:` in a workflow), install Docker Engine first, as in
  [Docker's guide](https://docs.docker.com/engine/install/ubuntu/), or with
  its script:

  ```bash
  curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
  ```

  Inside an LXC container, Docker needs nesting and keyctl enabled on the
  host (Proxmox: Options > Features).

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
  repository only, and is needed only to connect. Never commit it. On your
  development machine, where `gh` is signed in as an admin of the
  repository, this prints one to paste here:
  `gh api -X POST repos/YOUR_USERNAME/YOUR_PROJECT/actions/runners/registration-token --jq .token`
- `DIR` is the runner's folder. Keep it as it is for the first repository on
  the server.

## 2. Create the runner user

```bash
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
```

The `docker` group lets jobs use Docker; without it, they fail with
"permission denied" on `/var/run/docker.sock`. Installing Docker creates the
group; without Docker this line does nothing, and creating the group by hand
wouldn't help.

```bash
getent group docker >/dev/null && usermod -aG docker runner
```

Passwordless sudo, as on GitHub's own runners, for jobs that run
`sudo apt-get install` and the like. Skip it if your jobs never need root.

```bash
echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner
```

Docker access and sudo each make `runner` as powerful as root on this server,
which is why it isn't a development machine. Give projects that mustn't see
each other's jobs a server each.

## 3. Download the runner

Skip this step if `$DIR/config.sh` already exists.

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
restart every runner on the server so they pick up the group:

```bash
systemctl restart 'actions.runner.*'
```

## Use it in a workflow

```yaml
runs-on: self-hosted
```

Projects from dev-baseline's template read `runs-on` from the repository
variable `RUNS_ON` instead. Set it on your development machine, or wherever
`gh` is signed in:

```bash
gh variable set RUNS_ON --body self-hosted --repo YOUR_USERNAME/YOUR_PROJECT
```

`gh variable delete RUNS_ON --repo YOUR_USERNAME/YOUR_PROJECT` sends the jobs
back to GitHub's machines.

## More repositories

A runner belongs to one repository, but one server can run a runner for each
of your repositories:

- Each runner has its own folder, its own token from its own repository, and
  its own service, `actions.runner.OWNER-REPO.NAME`. They all run as the same
  `runner` user and start at boot.
- The token is needed once, to connect. A connected runner keeps its own
  credentials and keeps working after the token expires.
- Each runner takes one job at a time. Runners on one server run their jobs
  in parallel and share its CPU, memory, disk and Docker. Each repository
  only sends jobs to its own runners.
- They're independent: stopping, updating or removing one leaves the others
  alone.

For each further repository, set its values in a root shell. The folder is
named after the repository, so every server names it the same way:

```bash
REPO=YOUR_USERNAME/OTHER_PROJECT
TOKEN=ITS_RUNNER_TOKEN
DIR=/home/runner/actions-runner-${REPO/\//-}
```

Then run steps 3 to 6 again; the `runner` user from step 2 is already there.
Set `RUNS_ON` for that repository too. To see every runner on the server:

```bash
systemctl list-units 'actions.runner.*'
```

Each runner needs a folder of its own. Keep them in `/home/runner` like this:
[Take runners off a machine](#take-runners-off-a-machine) looks for them there.

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

## Take runners off a machine

To retire a runner server, or to clear a development machine that an older
version of dev-baseline gave a runner, remove every runner, the `runner` user
and its sudo rule. As root:

```bash
for dir in /home/runner/actions-runner*; do [ -f "$dir/svc.sh" ] && (cd "$dir" && ./svc.sh uninstall); done
pkill -u runner; userdel -r runner; rm -f /etc/sudoers.d/runner
```

`userdel -r` deletes `/home/runner` with every runner in it, and
`systemctl list-units --all 'actions.runner.*'` now lists nothing. A runner
that was connected to a repository still shows on GitHub as offline: delete
it under Settings > Actions > Runners, or remove it as in
[Remove it](#remove-it) first. Then delete that repository's `RUNS_ON`, or
its jobs wait for a runner that's gone.

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
