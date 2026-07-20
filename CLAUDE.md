# claude-gitflow

## Layout

- `scripts/claude-gitflow.sh` — all logic. Subcommands `rename` / `notify` / `end`
- `scripts/finish-branch.sh` - wrap-up, handles killing session & removing cruft
- `hooks/hooks.json` — wires subcommands to `PostToolUse[EnterWorktree]`, `Stop` (async), `SessionEnd`.

## Considerations

- Gitflow: feature branches off `develop` (configurable)
- Only targets `.claude/worktrees/`
- Pushing to remote only on user's go ahead
- Destructive steps (reset, detach) gated on user interaction


