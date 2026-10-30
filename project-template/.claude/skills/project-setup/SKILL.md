---
name: project-setup
description: Set up or repair the project's foundation. Covers choosing and wiring the language stack (mise, just, CI, Dependabot), GitHub repository settings (branch protection, merge rules, labels, security), and the AI reviews on GitHub. Use on a new repo, on a stack change, or when CI, labels or branch rules are missing.
---

# Project setup playbook

Do all of this yourself. Ask the user only for what "Needs a human" lists.

## GitHub repository settings

- `just repo-setup` is idempotent. It sets squash-only merges with auto-merge,
  protects `main` (PRs only, the `ci` check must pass, no force-push), creates
  the `agent` and `blocked` labels, and turns on Dependabot and secret scanning
  where the plan allows.
- Run it when the `main` ruleset is missing
  (`gh api repos/{owner}/{repo}/rulesets --jq '.[].name'`) or labels are absent.
- If rulesets fail on a private repo, tell the user once. It needs GitHub Pro
  or a public repo; until then nothing stops a broken PR from merging, so
  don't use `AUTO_MERGE`.

## Choosing and wiring a stack

1. Choose the stack from the project's goal (GSD's `PROJECT.md`), and record
   it, with the main alternative, in the GSD decisions or `PROJECT.md`.
2. `mise use <runtime>@<version>`, plus its package manager (`uv`, `pnpm`...).
3. Fill in the `STACK` lines of the `justfile`: `setup` installs
   dependencies, `fmt` formats, `lint` lints and type-checks, `test` runs the
   tests. `just check` must cover the new code.
4. CI already runs `just`; change `.github/workflows/ci.yml` only to add
   services (see the environments playbook). Never weaken or skip a check.
5. Add the ecosystem to `.github/dependabot.yml` (npm, pip or uv, gomod,
   cargo...) with the same 7-day cooldown.
6. CodeQL:
   `gh api -X PATCH repos/{owner}/{repo}/code-scanning/default-setup -f state=configured`.
   It works on public repos; skip on a 4xx (private repos need GitHub Code Security).

## AI reviews on GitHub

- Claude (`@claude`, plus a review of every PR) needs the Claude GitHub app and
  the `CLAUDE_CODE_OAUTH_TOKEN` secret. Check with
  `gh secret list | grep -q CLAUDE_CODE_OAUTH_TOKEN`. When it's present:
  `gh variable set CLAUDE_REVIEW --body true`.
- Codex review: when `gh secret list` shows `OPENAI_API_KEY`,
  `gh variable set CODEX_REVIEW --body true`.

## Needs a human (ask once, giving the exact step)

- Installing the Claude GitHub app: the user runs `/install-github-app` in an
  interactive Claude Code session, or opens https://github.com/apps/claude.
- Secret values: `claude setup-token`, then
  `gh secret set CLAUDE_CODE_OAUTH_TOKEN`; an OpenAI API key, then
  `gh secret set OPENAI_API_KEY`.
- Upgrading the GitHub plan, or making the repo public.
