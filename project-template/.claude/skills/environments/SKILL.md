---
name: environments
description: Run, add or publish anything this project needs, such as Docker containers and Compose stacks, development databases and caches, web apps and APIs served over HTTPS, new runtimes, and deployments. Use when a task needs a service running, a site reachable, or a new environment.
---

# Environments playbook

Do all of this yourself. Ask the user only for what "Needs a human" lists.

## What this machine has

- Ubuntu 24.04+, often an LXC container, possibly running as root.
- Docker Engine and Compose if `docker info` succeeds. If it fails inside LXC,
  the host must enable nesting and keyctl for the container: tell the user
  once, and meanwhile run things natively (see "Without Docker").
- Runtimes through mise: `mise use python@3.13` (or `node@24`, `go@1.25`,
  `uv`, `pnpm`, `bun`...) writes `mise.toml`, then `mise install`. Never build
  project code on the system Python or Node.
- Base domain for public sites: `cat ~/.config/dev-baseline/domain`. A
  wildcard DNS record points `*.<domain>` here, so any `<name>.<domain>` works
  with HTTPS and needs nobody. If the file is missing there is no public
  hostname: use `gh webhook forward` for webhooks, give the user an SSH tunnel
  for sites (`ssh -L 8080:localhost:8080 <server>`), or ask once for a domain
  and save it to that file.

## Development services: databases, caches, queues

1. Add them to `compose.dev.yaml` at the repo root, published on 127.0.0.1
   only:

   ```yaml
   services:
     postgres:
       image: postgres:17
       environment: { POSTGRES_PASSWORD: dev, POSTGRES_DB: app }
       ports: ["127.0.0.1:5432:5432"]
       volumes: [pgdata:/var/lib/postgresql/data]
       healthcheck: { test: ["CMD", "pg_isready"], interval: 5s }
   volumes: { pgdata: {} }
   ```

2. Add `just` recipes `services-up` (`docker compose -f compose.dev.yaml up -d
   --wait`) and `services-down`, and call `services-up` from `just setup`.
3. Put connection settings in `.env.example` as placeholders and in `.env`
   with real values.
4. In `.github/workflows/ci.yml`, start the same services before `just test`
   (a `services:` block, or a step that runs `just services-up`).

## A new app, service or environment

- One folder per service, `services/<name>/`, with its own `Dockerfile`:
  pinned base image, non-root user, `HEALTHCHECK`. Code and tests live beside it.
- Add it to `deploy/compose.yaml` without publishing ports; only Caddy
  publishes 80/443. Extend `just build` and the image step in
  `.github/workflows/release.yml` to cover it.
- Throwaway experiment: `docker compose -p try-<name> ...` or `docker run --rm
  -it -v "$PWD":/work -w /work <image> bash`. Remove it afterwards
  (`docker compose -p try-<name> down -v`).

## Publish a web app or API over HTTPS

1. Hostname: `<project>.<domain>` for the main site, `<part>.<project>.<domain>`
   for others. Set `DOMAIN=<project>.<domain>` in `.env`.
2. Add a site block to `deploy/Caddyfile`, for example
   `{$DOMAIN} { reverse_proxy app:3000 }` or `api.{$DOMAIN} { reverse_proxy api:8000 }`.
3. `just up`, then `curl -fsSI https://<hostname>` must answer.
4. Tell the user the URL.

## Several web projects on one machine

Only one container can own ports 80/443. If `docker ps --format '{{.Names}}
{{.Ports}}' | grep -E ':(80|443)->'` shows another project's Caddy, don't
start a second one. Instead:

1. Once per machine: a shared proxy in `~/edge/` with `compose.yaml` (image
   `caddy:2`, ports 80/443, external network `edge`, volume
   `./sites:/etc/caddy/sites`) and a `Caddyfile` with one line,
   `import /etc/caddy/sites/*.caddy`. Run `docker network create edge` first.
2. In this project's `deploy/compose.yaml`: remove the `caddy` service and
   attach the web services to the external network `edge` with a unique alias
   such as `<project>-app`.
3. Write `~/edge/sites/<project>.caddy` with this project's site blocks,
   pointing at those aliases, then
   `docker exec edge caddy reload --config /etc/caddy/Caddyfile`.

## Deploy

- On this machine: `just up` builds and starts `deploy/compose.yaml`.
- Elsewhere: every merge to `main` pushes images to GHCR (`release.yml`). Fill
  in its `deploy` job (SSH plus `docker compose pull && docker compose up -d`,
  or the platform's CLI), store credentials as environment secrets
  (`gh secret set NAME --env production`), then
  `gh variable set DEPLOY_ENABLED --body true`.
- If auto mode blocks a deploy as a production action, ask the user to confirm.

## Without Docker

Run services natively with mise runtimes and `just` recipes. Keep
long-running processes in a tmux window (`tmux new-window -d -n <name> '<cmd>'`)
or a systemd user unit (`systemctl --user`), never with `nohup`.

## Needs a human

- A DNS record, when there's no base domain with a wildcard.
- Enabling nesting and keyctl for Docker on an LXC host.
- Anything that costs money, or touches production data or production credentials.
