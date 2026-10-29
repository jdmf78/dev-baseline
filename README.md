# dev-baseline

A reproducible setup for developing on a remote Ubuntu server or container with
Claude Code, Codex, GitHub, webhooks and a CI/CD pipeline. One command turns a
fresh machine into a dev box for a GitHub repo you choose. It has two parts:

- **`machine/`** runs once per server. It installs the toolchain (including
  Claude Code, Codex and the latest Python), hardens SSH, creates a per-machine
  GitHub key, signs you in, and clones your project.
- **`project-template/`** seeds a new product repo. It brings CI, release, AI
  review, a GitHub webhook receiver, deploy files, and the rules agents follow.

The kit holds no secrets or personal details, so it can be public and any new
machine can clone it.

```
install.sh              one command: bootstrap + sign-in + your project
machine/
  bootstrap.sh          idempotent server setup (re-run any time)
  login.sh              interactive sign-in, once per machine
  cloud-init.yaml       provisions a brand-new VM the same way
  files/                default configs: Claude, Codex, tmux, git ignore
project-template/
  AGENTS.md, CLAUDE.md  one set of instructions for Codex and Claude Code
  .claude/settings.json shared permissions (allow `just`, deny .env reads)
  mise.toml, justfile   pinned tools + the single task interface (local = CI)
  .github/workflows/    ci, release (GHCR image), claude (@claude), codex-review
  .github/dependabot.yml
  scripts/              github-setup.sh (repo rules, webhook), webhook-redeliver.sh
  services/webhooks/    zero-dependency Node receiver with tests
  deploy/               Docker Compose + Caddy (automatic HTTPS)
  .devcontainer/        the same toolchain in Codespaces or any Docker host
```

## 1. Set up a server or container (one command)

Works on Ubuntu 24.04+ as root (the default in LXC containers) or as a user
with sudo. First create the GitHub repo you'll develop in, if it doesn't exist
yet; empty is fine:

```bash
gh repo create you/your-app --private
```

Then, on the new machine:

```bash
git clone https://github.com/YOUR_USER/dev-baseline.git ~/dev-baseline
```

```bash
~/dev-baseline/install.sh --project you/your-app --harden --web
```

The unattended part runs first (`machine/bootstrap.sh`), then the sign-ins and
project setup (`machine/login.sh`, section 2). No personal details are needed:
git uses your GitHub username and private noreply address unless you pass
`--git-name` and `--git-email`. Over SSH, keep a second session open during the
first `--harden` run. To run the two halves separately (cloud-init runs the
first), use `machine/bootstrap.sh` with the same options, then `machine/login.sh`.

What `bootstrap.sh` does (each step skips itself if already done):

| Area | Result |
|---|---|
| Packages | build tools, curl, git, screen, tmux, jq, ripgrep, fd, direnv, shellcheck, bubblewrap (agent sandboxes), automatic security updates |
| Python and tools | via mise: the latest Python (re-running upgrades it), Node 24, just, actionlint, gitleaks |
| Claude Code, Codex | both installed (Claude's native installer; Codex from npm via mise) or updated to the latest release, plus default settings if you have none |
| GitHub CLI | from GitHub's apt repo |
| Docker | Engine + compose + buildx from Docker's repo, log rotation |
| Git | sensible defaults, SSH commit signing, global ignore for `.env` and keys |
| SSH key | `~/.ssh/github_ed25519`, one per machine, GitHub host keys pinned from the API |
| Shell | mise + direnv activation; `dev` opens a tmux session in your project that survives SSH drops |
| `--harden` | key-only SSH, fail2ban, ufw denying inbound except SSH |
| `--web` | opens 80/443 so GitHub can reach your webhook endpoint |

### As root, and in containers

- Everything runs the same as root, without sudo.
- `--harden` run as root keeps root login, but with keys only
  (`PermitRootLogin prohibit-password`), so you can't lock yourself out. With
  no SSH server (you enter with `lxc exec` or `pct enter`) or no authorized key,
  it skips SSH hardening with a warning.
- Docker inside LXC needs nesting and keyctl (Proxmox: Options > Features).
  Without them the script rolls Docker back and carries on.
- ufw and fail2ban often can't run in unprivileged containers. The script warns
  and continues; firewall the container at the host instead.
- Agents running as root can change anything in the container, and the Claude
  Code and Codex sandboxes may not work inside one. Treat the container as the
  boundary and keep it disposable. Claude Code refuses
  `--dangerously-skip-permissions` as root unless you set `IS_SANDBOX=1`, which
  only makes sense in a throwaway container.

## 2. Sign-in and project setup (`machine/login.sh`)

`install.sh` runs this for you. Re-run it any time; finished steps are skipped.

- **GitHub CLI** uses the device flow: open the printed URL on your laptop or phone
  and enter the code. The script then uploads this machine's key for both
  authentication and commit signing, and installs the `gh webhook` extension.
- **Git identity**: if none is set, commits are authored as your GitHub username
  with `ID+username@users.noreply.github.com`, so they never carry your real
  name or email, and still show as Verified.
- **Codex** runs `codex login --device-auth`. If your ChatGPT account refuses
  device login, enable it in ChatGPT's security settings, or tunnel the callback:
  `ssh -L 1455:localhost:1455 your-server`, then run `codex login`.
- **Claude Code** runs `claude auth login`: open the printed URL on your laptop,
  approve, and paste the code back. Use `claude auth login --console` to bill an
  Anthropic Console account instead of a subscription.
- **Your project** is cloned to `~/code/REPO` over SSH. If it has a `mise.toml`
  or a `just setup` recipe, those run too, and `dev` opens in that folder.

To switch projects, or to add another one, run
`machine/login.sh --project you/other-app`; `dev` follows the latest.

## 3. Starting a new project from the template

If the `--project` repo is empty, `login.sh` offers to start it from
`project-template/`: it copies the files in, runs `just setup`, pushes the first
commit, and offers to run `scripts/github-setup.sh`. You can also run that
script yourself later from inside the project.

`github-setup.sh` configures squash-only merges, branch auto-delete, Dependabot
alerts and fixes, secret scanning (where your plan allows), a `production`
environment, and a ruleset on `main`: PRs only, the `ci` check must pass, no
force-push or deletion. That ruleset applies to you and your agents alike.

An existing project keeps its own files. Copy over the template pieces you
want, such as `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json` or the workflows.

## 4. The daily loop

```
dev (tmux) -> claude / codex on a branch -> just ci -> push -> PR
  -> CI (lint, test, build) + optional @claude / Codex review
  -> squash merge to main -> release.yml pushes ghcr.io/<you>/<repo>/webhooks
  -> deploy job (off until you set DEPLOY_ENABLED)
```

`just` is the contract: CI runs `just ci`, agents are allowed `just *`, and you
type the same commands. When the stack changes you edit recipes, not workflows.

## 5. Webhooks (GitHub events into your code)

**Developing** (no public URL needed), in two tmux panes:

```bash
just dev
```

```bash
just webhook-forward
```

`webhook-forward` relays real events from `GITHUB_REPO` (set in `.env`) through
GitHub's forwarder to localhost. `just webhook-ping` sends a signed fake event
without GitHub at all.

**Running it on this server**: point a DNS record (e.g. `hooks.example.com`)
at the server, set `DOMAIN` and `WEBHOOK_SECRET` in `.env`, then:

```bash
just up
```

```bash
scripts/github-setup.sh --webhook-url https://hooks.example.com/webhook
```

Check the delivery under the repo's Settings > Webhooks > Recent Deliveries.
GitHub does not retry failures, so after downtime run
`scripts/webhook-redeliver.sh https://hooks.example.com/webhook 48`.

Already built into `services/webhooks/` (and covered by its tests):

- HMAC-SHA256 signature check on the raw body, compared in constant time
- reply within GitHub's 10-second limit, then do the work
- duplicate delivery GUIDs skipped; a failed handler can be redelivered
- payload size limit, JSON content type enforced, loopback-only by default
- only Caddy is published; the service has no public port

Move to a **GitHub App** once you need events from many repos or orgs, or want
to call the GitHub API with short-lived, narrowly scoped tokens instead of a
personal token.

## 6. AI in GitHub

- **Claude**: inside Claude Code in the repo, run `/install-github-app`. It installs
  the app and adds the secret. Then mention `@claude` in an issue or PR. Only
  owners, members and collaborators can trigger it.
- **Codex**: either enable Codex code review for the repo in Codex cloud, or use
  the bundled workflow: `gh secret set OPENAI_API_KEY`, then
  `gh variable set CODEX_REVIEW --body true`.

## 7. Replicating to another environment

| Layer | Lives in | Reproduce with |
|---|---|---|
| Machine | `install.sh`, `machine/` | clone + `install.sh --project …` on any Ubuntu box or container; `cloud-init.yaml` for a new VM |
| Toolchain | repo `mise.toml` | `just setup`; mise-action in CI; the devcontainer |
| Tasks | repo `justfile` | identical commands everywhere |
| Agent rules | `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json` | committed with the code |
| GitHub settings | `scripts/github-setup.sh` | re-run per repo |
| Secrets | never in git | `.env` per machine, GitHub secrets per repo, `login.sh` per machine |

For a laptop or Codespaces, open the repo in its devcontainer and you get the
same tools without running `bootstrap.sh`.

## 8. Why it is set up this way

- **The server holds powerful credentials.** The device-login GitHub token can
  change repo settings, including the ruleset. After `github-setup.sh`, consider
  switching the server to a fine-grained token limited to your product repos
  (Contents, Pull requests, Issues, Workflows and Webhooks read/write, no
  Administration), and run admin tasks from your laptop:
  `gh auth login --with-token < token.txt`.
- **Permission rules are guardrails, not walls.** The real boundaries are the
  sandboxes (enable Claude Code's with `/sandbox`; Codex defaults to
  workspace-write with no network), Unix permissions and GitHub's ruleset.
- **The docker group is root-equivalent**, and Docker-published ports bypass
  ufw. The compose file publishes only Caddy.
- **One SSH key per machine.** If a server is compromised, delete just its key
  in GitHub > Settings > SSH and GPG keys.
- **Supply chain**: actions are pinned to commit SHAs, and Dependabot bumps them
  weekly after a 7-day cooldown. Images get SBOM and provenance attestations.
- **Plan limits**: on private repos, rulesets and environment reviewers need
  GitHub Pro or Team, and secret scanning needs Secret Protection. The script
  warns and carries on; gitleaks in CI and the pre-commit hook still apply.

## 9. Using it anonymously

Nothing in this repo identifies its owner, and no setup step asks for your name.

- **Commits** use your GitHub username and noreply address (see section 2).
  Once per account, under GitHub > Settings > Emails, turn on "Keep my email
  addresses private" and "Block command line pushes that expose my email". The
  second makes GitHub refuse any push that still carries your real address.
- **Your GitHub username stays visible** on every repo and commit. If that
  matters, do this work from a separate GitHub account; the kit works with
  whichever account logs in.
- **AI logins stay on the machine.** Claude Code and Codex keep their tokens in
  `~/.claude` and `~/.codex` on each server, never in a repo. Changes made by
  the Claude GitHub Action are committed as `claude[bot]`.
- **Placeholders** (`YOUR_USER`, `you@laptop`, `myproduct`) are the only names in
  the kit. Fill them in on your servers and product repos, not in a public copy.

## 10. When you choose a stack

1. Add the runtime to `mise.toml` (e.g. `python = "3.13"`, `go = "1.25"`).
2. Fill in the `STACK` lines in the `justfile` (setup, fmt, lint).
3. Add the ecosystem to `.github/dependabot.yml`.
4. Turn on CodeQL: `gh api -X PATCH repos/OWNER/REPO/code-scanning/default-setup -f state=configured`
   (free for public repos; private needs GitHub Code Security).
5. Keep `services/webhooks/` as its own small service, or port its handlers.
