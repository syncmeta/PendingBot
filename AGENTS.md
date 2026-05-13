# Codex workflow conventions

Use this together with `CLAUDE.md`, which is the detailed source of truth for this repo's branch, worktree, merge, test, deploy, and cleanup conventions.

## First action before edits

- Before changing files in any session, check `git branch --show-current` and `pwd`.
- Create or switch to an appropriate branch before editing. Use the `codex/` prefix for Codex-created branches unless the user asks for a specific branch name.
- Do not make code changes directly on `main`.
- If Git metadata writes are blocked by sandbox permissions, request escalation for the Git branch/switch operation rather than editing first.

## Small changes

- For small, focused changes with no conflicts, finish the loop without waiting for extra confirmation:
  1. make the change on the branch,
  2. run the relevant checks,
  3. commit the change when appropriate,
  4. merge it back to `main` if the branch is clean and the merge is conflict-free.
- Follow the merge sizing and check guidance in `CLAUDE.md`.
- Treat local `main` as the source of truth. Do not fetch or rebase against `origin/main` during the normal merge flow; the remote is only a backup.
- Do not auto-deploy after merging; deploys remain deliberate and user-initiated.

## Preserve user work

- Treat unrecognized dirty files as user work. Do not revert or overwrite them.
- If an existing change affects the task, work with it and only ask the user when it makes the requested work impossible.
