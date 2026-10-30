# dev-baseline

One command turns an Ubuntu server or container into a complete development
setup where AI coding agents work like a full engineering team on your
project: Claude Code, Codex and OpenCode, all three or the ones you pick. You
set the goal; they plan it, build it in parallel, review it, test it and ship
it as pull requests.

## Install

On Ubuntu 24.04 or newer, as root (put `sudo` in front of `apt` otherwise):

```bash
apt update && apt install -y git gh curl
```

```bash
git clone https://github.com/jdmf78/dev-baseline.git ~/dev-baseline
```

```bash
~/dev-baseline/install.sh --project YOUR_USERNAME/YOUR_PROJECT
```

`YOUR_USERNAME/YOUR_PROJECT` is the GitHub repository you're building, written
as in its address: `github.com/octocat/invoice-api` becomes
`octocat/invoice-api`. If it doesn't exist yet, the installer creates it
(private), and fills an empty one from the project template.

It installs all three AI tools. To pick, add `--agents` with the ones you want,
for example `--agents claude` or `--agents codex,opencode`.

The installer runs on its own for a few minutes, then asks you to sign in to
GitHub and to each AI tool. Each shows a link and a code to approve on your
phone or laptop; OpenCode first asks which model provider you use. That's the
only part that needs you. It ends in a fresh shell.

## Use it

```bash
dev
```

`dev` opens your project in a session that keeps running when you disconnect.
Start your AI tool, `claude`, `codex` or `opencode`:

```bash
claude
```

Then describe what you want built:

```
/gsd-new-project
```

GSD turns your description into a roadmap of phases. Let the team build it:

```
/gsd-autonomous
```

Or unattended with Claude Code, for example overnight, merging the result
once CI passes:

```bash
AUTO_MERGE=1 just autopilot
```

For anything else, ask in plain words: "add a Postgres database", "put it
online", "set up the GitHub webhooks", "deploy it". The agents follow the
playbooks in the project and only come back to you for what they can't do
themselves, such as a sign-in or a DNS record. Codex and OpenCode take the
same `/gsd-...` commands.

Another project on the same machine:

```bash
~/dev-baseline/machine/login.sh --project YOUR_USERNAME/OTHER_PROJECT
```

## Options

| Option | Use it when |
|---|---|
| `--agents claude,codex,opencode` | You want fewer AI tools than all three. List the ones to install. Later runs keep your choice until you give a new list. |
| `--domain dev.example.com` | Projects should be reachable on the web: sites, APIs, webhooks. First point a wildcard DNS record, `*.dev.example.com`, at this machine. Agents then publish each project at `NAME.dev.example.com` with HTTPS, without asking you. |
| `--harden` | The machine is reachable from the internet: SSH keys only, firewall, fail2ban. Copy your laptop's key to it first (`ssh-copy-id root@your-server`); without a key there, password login stays on. Not needed for local containers. |
| `--no-docker` | You don't want Docker. |

There's no GitHub SSH key to set up and no name or email to give. The
installer creates a key for the machine, and commits use your GitHub username
with a private noreply address.

## What's inside

| Part | Job |
|---|---|
| [GSD Core](https://github.com/open-gsd/gsd-core) | Plans and builds: goal → phases → parallel waves of agents → verified → pull request |
| [gstack](https://github.com/garrytan/gstack) | Checks quality: code and design review, browser QA, security audits |
| `machine/` | Installs your pick of Claude Code, Codex and OpenCode, plus GSD Core, gstack, Docker, gh, git, the latest Python, Node, Bun, just, tmux, screen and curl, then signs you in and clones your project |
| `project-template/` | What every new project starts with: rules for agents (`AGENTS.md`), playbooks so they set up Docker, websites, webhooks, deploys and GitHub settings on their own, CI/CD, branch protection, a webhook receiver, HTTPS through Caddy |

The safeguards: `main` only accepts pull requests that pass CI, agents never
merge (you do, or the autopilot when `AUTO_MERGE=1`), GSD verifies every
phase, and Codex, when installed, reviews the code as a second opinion.

## Good to know

- Run `install.sh` again any time. It skips what's done, and updates the AI
  tools, GSD, gstack and Python.
- Works as root in LXC containers. Docker inside LXC needs nesting and keyctl
  enabled on the host (Proxmox: Options > Features).
- Agents running as root can change anything in their container, so give each
  project its own disposable container.
- On GitHub's free plan, private repos can't have branch protection. Use GitHub
  Pro or a public repo before turning on `AUTO_MERGE`.
- Every parallel agent is its own AI session, so cost grows with parallelism.
  Cap each autopilot run with `AUTOPILOT_BUDGET_USD` (default 25, estimated).
- For a brand-new VM, `machine/cloud-init.yaml` runs the unattended part while
  the VM is created.
