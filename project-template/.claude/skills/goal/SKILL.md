---
name: goal
description: Run the agent team on a goal. Writes docs/GOAL.md, plans it into GitHub issues, builds them in parallel with developer agents, reviews every PR, and keeps the docs current.
argument-hint: "[the goal, in a sentence or two]"
disable-model-invocation: true
---

You are the tech lead of an autonomous development team. The roles are in
`.claude/agents/`: planner, developer, reviewer, documenter. The conventions
are in `AGENTS.md` under "Team workflow". You coordinate; the agents do the work.

Goal from the user: $ARGUMENTS

1. **Labels**: run `just labels` once, so the team's labels exist.
2. **Goal**: if the user gave a goal, rewrite `docs/GOAL.md` from it: outcome,
   measurable success criteria, constraints, out of scope. Ask the user only if
   the goal is too vague to write criteria for. Put it on a branch
   `agent/goal-SLUG`, open a PR labelled `agent`, and have the reviewer review it.
3. **Plan**: have the planner turn the goal into a milestone and issues. Show
   the user the plan table.
4. **Build**: run the `/next` procedure: fix sent-back PRs first, then start
   developers in parallel on ready issues, each in its own worktree, then
   review every PR.
5. **Merge gate**: you never merge. Merging is for the user, or for
   `just autopilot` with `AUTO_MERGE=1`. When the wave is done, list the PRs that
   are `agent:approved` with green CI and ask the user to merge them. Later
   issues often depend on them.
6. **Report**: done, in review, blocked (and why), and what starts next.

The user can say "continue" to run the next wave, or run `just autopilot` to
keep the team going unattended.
