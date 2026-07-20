#!/usr/bin/env bash
# claude-gitflow finish-branch — deterministic Sourcetree-style "Finish Feature".
#
# Modes (wired to the /finish-branch command in commands/finish-branch.md):
#   plan   <branch>   read-only: resolve branch/base/worktree/session and print
#                     exactly what `finish` would do; makes NO changes
#   finish <branch> [--kill-session] [--delete-branch]
#                     merge <branch> into the gitflow base with --no-ff.
#                     On conflict: abort, push the branch and open a PR instead
#                     (the only case where anything is pushed). Destructive
#                     steps are OFF unless their flag is passed:
#                       --kill-session   kill the Claude session attached to the
#                                        branch's worktree and delete its job dir
#                       --delete-branch  remove the worktree and delete the branch
#
# Unlike the hook script (claude-gitflow.sh), this is user-invoked and MUST
# fail loudly. Exit codes:
#   0 ok   2 refused/preflight failed   3 merge conflict (PR route taken)
#   4 cleanup incomplete
#
# Configuration: CLAUDE_GITFLOW_PREFIX, CLAUDE_GITFLOW_BASE (same as hooks).
set -u

mode="${1:-}"; shift 2>/dev/null || true
PREFIX="${CLAUDE_GITFLOW_PREFIX:-feature/}"
BASE_OVERRIDE="${CLAUDE_GITFLOW_BASE:-}"

branch_arg=""; kill_session=0; delete_branch=0
for a in "$@"; do
  case "$a" in
    --kill-session) kill_session=1 ;;
    --delete-branch) delete_branch=1 ;;
    --*) echo "error: unknown flag $a" >&2; exit 2 ;;
    *) branch_arg="$a" ;;
  esac
done

case "$mode" in plan|finish) ;; *)
  echo "usage: finish-branch.sh plan|finish <branch> [--kill-session] [--delete-branch]" >&2
  exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 2; }

# --- main checkout root (works when invoked from a worktree) ----------------
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || fail "not inside a git repository"
root="${common%/.git}"
G() { git -C "$root" "$@"; }

# --- resolve target branch ---------------------------------------------------
resolve_branch() {
  local b="$1"
  if [ -n "$b" ]; then
    for c in "$b" "${PREFIX}${b}" "feature/$b" "bugfix/$b" "hotfix/$b"; do
      if G show-ref --verify -q "refs/heads/$c"; then printf '%s' "$c"; return 0; fi
    done
    echo "candidates:" >&2
    G for-each-ref --format='%(refname:short)' \
      "refs/heads/${PREFIX}" refs/heads/feature refs/heads/bugfix refs/heads/hotfix | sort -u >&2
    return 1
  fi
  # no argument: current branch if it looks like a gitflow work branch
  b="$(git symbolic-ref --short -q HEAD || true)"
  case "$b" in
    "$PREFIX"*|feature/*|bugfix/*|hotfix/*) printf '%s' "$b"; return 0 ;;
  esac
  # else: exactly one candidate branch in the repo
  local list; list="$(G for-each-ref --format='%(refname:short)' \
    "refs/heads/${PREFIX}" refs/heads/feature refs/heads/bugfix refs/heads/hotfix | sort -u)"
  if [ "$(printf '%s\n' "$list" | grep -c .)" = "1" ]; then printf '%s' "$list"; return 0; fi
  echo "candidates:" >&2; printf '%s\n' "$list" >&2
  return 1
}

branch="$(resolve_branch "$branch_arg")" \
  || fail "cannot resolve a single work branch — pass one explicitly (see candidates above)"

# --- resolve base branch -----------------------------------------------------
base=""
if [ -n "$BASE_OVERRIDE" ]; then
  G show-ref --verify -q "refs/heads/$BASE_OVERRIDE" \
    || fail "CLAUDE_GITFLOW_BASE=$BASE_OVERRIDE is not a local branch"
  base="$BASE_OVERRIDE"
else
  for b in develop dev; do
    if G show-ref --verify -q "refs/heads/$b"; then base="$b"; break; fi
  done
fi
[ -n "$base" ] || fail "no local base branch (develop/dev) — set CLAUDE_GITFLOW_BASE"
[ "$branch" = "$base" ] && fail "refusing: $branch is the base branch"

ahead="$(G rev-list --count "$base..$branch" 2>/dev/null || echo 0)"

# --- locate the worktree holding the branch ---------------------------------
wt_dir=""; wt_locked=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur="${line#worktree }" ;;
    "branch refs/heads/$branch") wt_dir="$cur" ;;
    "locked"*) [ "${cur:-}" = "$wt_dir" ] && [ -n "$wt_dir" ] && wt_locked=1 ;;
  esac
done <<EOF
$(G worktree list --porcelain)
EOF
[ "$wt_dir" = "$root" ] && wt_dir=""   # branch checked out in the main clone is not a lock

norm() { printf '%s' "$1" | tr 'A-Z\\' 'a-z/'; }
wt_is_managed=0
case "$(norm "$wt_dir")" in */.claude/worktrees/*) wt_is_managed=1 ;; esac
here="$(pwd -W 2>/dev/null || pwd)"   # -W: Git Bash prints the Windows-style path
wt_is_self=0
if [ -n "$wt_dir" ]; then
  case "$(norm "$here")/" in "$(norm "$wt_dir")"/*) wt_is_self=1 ;; esac
fi

# --- locate the Claude job/session attached to the worktree ------------------
job_field() { # file key -> value
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$2 // empty" <"$1" 2>/dev/null
  else
    sed -n 's/.*"'"$2"'": *"\([^"]*\)".*/\1/p' "$1" | head -1
  fi
}
job_dir=""; job_session=""
if [ -n "$wt_dir" ]; then
  for st in "$HOME"/.claude/jobs/*/state.json; do
    [ -f "$st" ] || continue
    jwt="$(job_field "$st" worktreePath)"
    [ -n "$jwt" ] || continue
    if [ "$(norm "$jwt")" = "$(norm "$wt_dir")" ]; then
      job_dir="$(dirname "$st")"
      job_session="$(job_field "$st" sessionId)"
      break
    fi
  done
fi
job_is_self=0
if [ -n "$job_dir" ] && [ -n "${CLAUDE_JOB_DIR:-}" ]; then
  [ "$(basename "$job_dir")" = "$(basename "$CLAUDE_JOB_DIR")" ] && job_is_self=1
fi

# ============================== plan =========================================
if [ "$mode" = "plan" ]; then
  echo "plan: branch        $branch ($ahead commit(s) ahead of $base)"
  echo "plan: base          $base"
  if [ -n "$wt_dir" ]; then
    st="clean"; [ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null)" ] && st="DIRTY"
    lk=""; [ "$wt_locked" = "1" ] && lk=", git-locked"
    slf=""; [ "$wt_is_self" = "1" ] && slf=" (this session's own worktree)"
    echo "plan: worktree      $wt_dir ($st$lk)$slf"
    if [ "$st" = "DIRTY" ]; then
      if [ "$ahead" = "0" ]; then
        echo "plan: NOTE          uncommitted worktree changes are NOT in $base — --delete-branch will DISCARD them"
      else
        echo "plan: NOTE          worktree is DIRTY — finish will refuse until the work is committed"
      fi
    fi
  else
    echo "plan: worktree      none — branch is not checked out anywhere"
  fi
  if [ -n "$job_dir" ]; then
    slf=""; [ "$job_is_self" = "1" ] && slf=" (this session — will refuse to kill)"
    echo "plan: session       job $(basename "$job_dir"), session $job_session$slf"
  else
    echo "plan: session       none found for this worktree"
  fi
  if [ "$ahead" = "0" ]; then
    echo "plan: merge         nothing to merge (already in $base) — finish = cleanup only"
  elif G merge-tree --write-tree "$base" "$branch" >/dev/null 2>&1; then
    echo "plan: merge         clean --no-ff merge into $base expected"
  elif G merge-tree --write-tree "$base" "$branch" 2>/dev/null | grep -q .; then
    echo "plan: merge         CONFLICTS expected — finish will push + open a PR instead"
  else
    echo "plan: merge         conflict prediction unavailable (git < 2.38) — finish will try and abort safely"
  fi
  echo "plan: kill-session  $( [ -n "$job_dir" ] && echo "kill session process + delete $(basename "$job_dir")" || echo "nothing to do" ) [requires --kill-session]"
  echo "plan: delete-branch remove worktree (if any) + git branch -d $branch [requires --delete-branch]"
  exit 0
fi

# ============================== finish =======================================
# Phase 1: preflight — never start a merge we may not be able to complete.
# -uno: untracked files (e.g. .claude/worktrees/ itself) never block a finish;
# tracked modifications do. .claude/worktrees is excluded entirely: worktrees
# accidentally committed as gitlinks (git add -A) must not brick the finish.
[ -n "$(G status --porcelain -uno -- . ':(exclude).claude/worktrees' 2>/dev/null)" ] \
  && fail "main checkout has uncommitted changes — commit or stash them first"
G rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
  && fail "main checkout has a merge in progress"
wt_discard=0
if [ -n "$wt_dir" ]; then
  if [ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null)" ]; then
    # Dirty means unfinished — except when the branch is already contained in
    # the base and the user consented to --delete-branch: the leftovers go
    # with the worktree (the /finish-branch consent prompt spells this out).
    if [ "$ahead" != "0" ] || [ "$delete_branch" != "1" ]; then
      fail "worktree $wt_dir has uncommitted changes — the branch is not finished"
    fi
    wt_discard=1
    echo "warn: worktree has uncommitted changes — discarding them with the worktree (--delete-branch on an already-merged branch)"
  fi
  [ "$wt_is_managed" = "1" ] \
    || fail "worktree $wt_dir was not created by Claude — release it yourself, then re-run"
fi

# Phase 2: release the lock — detach the worktree so the branch is free.
if [ -n "$wt_dir" ]; then
  [ "$wt_locked" = "1" ] && G worktree unlock "$wt_dir" 2>/dev/null
  git -C "$wt_dir" switch --detach -q || fail "could not detach worktree $wt_dir"
  echo "ok: released $branch from $wt_dir"
fi

# Phase 3: merge into base (or PR route on conflict).
G switch -q "$base" || fail "could not switch main checkout to $base"
if G rev-parse -q --verify "@{upstream}" >/dev/null 2>&1; then
  G pull --ff-only -q 2>/dev/null || echo "warn: $base diverged from upstream; merging into local $base"
fi
if [ "$ahead" = "0" ]; then
  echo "ok: $branch is already contained in $base — skipping merge"
elif G merge --no-ff --no-edit -m "Merge branch '$branch' into $base" "$branch" >/dev/null 2>&1; then
  echo "ok: merged $branch into $base (--no-ff): $(G rev-parse --short HEAD)"
else
  conflicts="$(G diff --name-only --diff-filter=U 2>/dev/null)"
  G merge --abort 2>/dev/null
  echo "conflict: merge of $branch into $base conflicts on:"
  printf '%s\n' "$conflicts" | sed 's/^/conflict:   /'
  if G remote get-url origin >/dev/null 2>&1; then
    G push -u origin "$branch" || fail "conflict + push failed — resolve manually"
    if command -v gh >/dev/null 2>&1; then
      pr_body="Opened by /finish-branch: the local --no-ff merge of \`$branch\` into \`$base\` hit conflicts, so the finish switched to the PR route.

**When this PR is merged, the finish is not done yet** — run \`/finish-branch $branch\` again to resume it. The command will detect the branch is now contained in \`$base\` and complete the remaining steps: verify the worktree lock is released, and (with your go-ahead) kill the attached session and delete the branch."
      url="$(cd "$root" && gh pr create --base "$base" --head "$branch" \
        --title "Merge $branch into $base" \
        --body "$pr_body" 2>/dev/null)"
      [ -n "$url" ] && echo "conflict: PR opened: $url" || echo "conflict: branch pushed; open the PR manually (gh pr create failed)"
    else
      echo "conflict: branch pushed to origin; open a PR into $base manually (gh not installed)"
    fi
    echo "conflict: branch and worktree left intact — re-run /finish-branch $branch after the PR merges to resume"
  else
    echo "conflict: no remote — resolve the merge manually (branch and worktree left intact)"
  fi
  exit 3
fi

# Phase 4: kill the attached session (opt-in via --kill-session).
if [ "$kill_session" = "1" ] && [ -n "$job_dir" ]; then
  if [ "$job_is_self" = "1" ]; then
    echo "warn: refusing to kill this session's own job ($(basename "$job_dir")) — end the session normally"
  else
    if [ -n "$job_session" ]; then
      if command -v powershell.exe >/dev/null 2>&1; then
        SID="$job_session" powershell.exe -NoProfile -Command '
          Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -match [regex]::Escape($env:SID) -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1
      elif command -v pgrep >/dev/null 2>&1; then
        for p in $(pgrep -f "$job_session" 2>/dev/null); do
          [ "$p" != "$$" ] && kill "$p" 2>/dev/null
        done
      fi
    fi
    rm -rf "$job_dir" && echo "ok: session killed and job $(basename "$job_dir") deleted"
  fi
elif [ "$kill_session" = "1" ]; then
  echo "ok: no session/job found for $branch — nothing to kill"
fi

# Phase 5: delete worktree + branch (opt-in via --delete-branch).
incomplete=0
if [ "$delete_branch" = "1" ]; then
  if [ -n "$wt_dir" ]; then
    if [ "$wt_is_self" = "1" ]; then
      echo "warn: not removing $wt_dir — this session is running inside it"
      incomplete=1
    else
      G worktree remove "$wt_dir" 2>/dev/null || G worktree remove --force "$wt_dir" 2>/dev/null \
        || { echo "warn: could not remove worktree $wt_dir" >&2; incomplete=1; }
    fi
    G worktree prune 2>/dev/null
  fi
  # -d only: git itself verifies the branch is fully merged; never force.
  if G branch -d "$branch" >/dev/null 2>&1; then
    echo "ok: deleted branch $branch"
  else
    echo "warn: git refused to delete $branch (not fully merged?) — left in place" >&2
    incomplete=1
  fi
else
  echo "ok: branch $branch kept (deletion requires --delete-branch)"
fi

echo "done: $branch -> $base on $(G rev-parse --short "$base")"
[ "$incomplete" = "1" ] && exit 4
exit 0
