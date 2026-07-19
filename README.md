# claude-gitflow

Gitflow guardrails for [Claude Code](https://claude.com/claude-code) worktrees.

Claude Code isolates background and parallel work in git worktrees on internal
`worktree-*` branches. Those branches don't follow gitflow naming, stay checked
out inside the worktree (so Sourcetree/GitKraken/git can't check them out —
`fatal: '<branch>' is already used by worktree at ...`), and nothing tells you
when the work is done. This plugin fixes all three:

- **Gitflow naming** — the moment a worktree is created, its branch is renamed
  to `feature/<name>`.
- **Fork from develop** — fresh worktrees are re-pointed to your gitflow base
  branch (`develop` by default), never whatever you happened to have checked out.
- **Completion alerts** — when new committed work exists, you get a desktop
  notification (Windows toast / macOS Notification Center / Linux
  `notify-send`) and, optionally, an [IFTTT](https://ifttt.com) webhook you can
  build any automation on.
- **Local delivery** — at session end the worktree's HEAD is detached, which
  releases the `feature/*` branch so your git client can check it out or merge
  it immediately. Your repo is the remote: **nothing is ever pushed anywhere.**

## Requirements

- git ≥ 2.31
- bash (on Windows: Git Bash, which ships with Git for Windows)
- `jq` optional (a sed fallback is built in)
- a recent Claude Code — the rename hook matches the `EnterWorktree` tool and
  the notify hook uses `async` Stop hooks. Older versions degrade gracefully:
  no rename, and alerts run synchronously.

## Installation

```
/plugin marketplace add jagp/claude-gitflow
/plugin install claude-gitflow@claude-gitflow
```

Or test locally:

```
claude --plugin-dir /path/to/claude-gitflow
```

> If you previously wired similar hooks directly into `~/.claude/settings.json`,
> remove them when installing this plugin — otherwise both will fire.

## How it works

| Hook | Event | What it does |
|------|-------|--------------|
| rename | `PostToolUse` on `EnterWorktree` | Renames `worktree-<name>` → `feature/<name>`. If the branch is *fresh* (a single `branch: Created from ...` reflog entry), hard-resets it onto the base branch first. Worktrees that already carry commits are never reset. |
| notify | `Stop` (async) | If the worktree is clean and HEAD moved since the last alert, sends the desktop notification + IFTTT webhook. Deduped by commit SHA — one alert per batch of new work, not per turn. |
| end | `SessionEnd` | Sends any pending alert, then detaches the worktree HEAD (releases the branch) so it is free in your main checkout. |

Everything is scoped to directories under `.claude/worktrees/` — the hooks
never touch your own branches or checkouts. The script always exits 0; a
guardrail must never break a session.

## Configuration

All optional, via environment variables (e.g. the `"env"` block in
`~/.claude/settings.json`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_GITFLOW_PREFIX` | `feature/` | Branch prefix for renamed worktree branches |
| `CLAUDE_GITFLOW_BASE` | auto | Base branch to fork from. Auto-detect order: `develop`, `dev`, `origin/develop`, `origin/dev`. If none exist, worktrees keep their default base. |
| `CLAUDE_GITFLOW_IFTTT_EVENT` | `claude_work_done` | IFTTT Maker Webhooks event name |
| `CLAUDE_GITFLOW_IFTTT_KEY_FILE` | `~/.claude/ifttt-key.txt` | Where your IFTTT Maker key lives |

### IFTTT setup (optional)

1. Get your key at [ifttt.com/maker_webhooks](https://ifttt.com/maker_webhooks) → Documentation.
2. Paste it into `~/.claude/ifttt-key.txt`.
3. Create an applet triggered by Webhooks event `claude_work_done`.
   Ingredients: `value1` = repo name, `value2` = branch, `value3` = detail text.

No key file → the webhook is silently skipped.

Keep the key file private (`chmod 600 ~/.claude/ifttt-key.txt` on macOS/Linux).
When a key is present, each alert sends the repo name, branch name, and alert
text to IFTTT — nothing else, and nothing at all without a key file.

## Reviewing and merging Claude's work

When you get the alert, the `feature/<name>` branch is (or will be at session
end) checked out nowhere — open your git client, review it, and merge it into
`develop` like any other feature branch. Delete it after merging as usual.

## License

MIT — see [LICENSE](LICENSE).
