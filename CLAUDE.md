# claude-gitflow

Claude Code plugin: gitflow guardrails for Claude-created worktrees. Pure bash + JSON — no build, no dependencies (jq optional, sed fallback), no tests.

## Layout

- `scripts/claude-gitflow.sh` — all logic. Subcommands `rename` / `notify` / `end`; the header comment is the authoritative doc for behavior and env vars.
- `hooks/hooks.json` — wires subcommands to `PostToolUse[EnterWorktree]`, `Stop` (async), `SessionEnd`.
- `.claude-plugin/plugin.json`, `marketplace.json` — manifest; bump `version` on release.

## Invariants — never violate

- The script always exits 0. A guardrail must never break a session.
- Only acts on worktrees under `.claude/worktrees/`; never touches the user's own branches or checkouts.
- Nothing is ever pushed or sent to a remote. Releasing the branch locally is the delivery.
- Destructive steps (reset, detach) run only on explicit signals — e.g. reset only a fresh worktree (single reflog entry), never one carrying commits.
- Prefer deterministic script logic over prompt/checklist instructions.
- Bash must run on Git Bash (Windows), macOS, and Linux.

## Workflow

- Gitflow: feature branches off `develop`, merge back to `develop`; releases via `release/*` into `main`.
- Any change to hook events, env vars, or subcommand behavior must update README.md and the script header in the same commit.
