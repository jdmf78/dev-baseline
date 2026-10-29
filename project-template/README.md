# myproduct

One sentence on what this product does.

## Getting started

```bash
just setup    # pinned tools, git hooks, .env from .env.example
just dev      # webhook service on http://localhost:3000
just ci       # what CI runs: lint, test, build
```

Run `just` with no arguments to list every recipe. Conventions for humans and
AI agents are in [AGENTS.md](AGENTS.md).

## Repository settings

`scripts/github-setup.sh` applies branch rules, merge settings, security
features and (with `--webhook-url`) the GitHub webhook. It is safe to re-run.
