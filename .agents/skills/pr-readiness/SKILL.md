---
name: pr-readiness
description: >-
  Prepare, audit, or rewrite a pull request before it is opened, updated,
  commented on, or presented to a maintainer.
  Use when a user asks to create a PR, ask someone to merge a PR, replace an
  upstream PR from a fork, comment on a PR, publish branch work, or make sure a
  PR is maintainer-ready.
---

# pr-readiness

Use this before any public PR action: opening a PR, updating a PR body, asking a
maintainer to merge, commenting with a replacement branch, or presenting a PR as
ready.
The goal is to avoid wasting maintainer attention with stale branches,
missing research, internal transcript language, or weak validation.
When opening a GitHub PR from firstmate workflows, use `bin/fm-pr-create.sh`
instead of `gh-axi pr create` directly.
If that wrapper refuses because no upstream target was explicitly approved, stop
and report the branch as ready for firstmate's local-main review instead of
creating a PR.

## Required checks

1. Refresh the base facts for the actual action.

   For an existing PR, capture both the base branch and the base repository
   before comparing or fetching:
   ```sh
   gh-axi pr view <number> --json number,title,author,mergeStateStatus,statusCheckRollup,changedFiles,additions,deletions,url
   gh-axi api repos/<owner>/<repo>/pulls/<number> --jq '{mergeable,mergeable_state,rebaseable,head:{repo:.head.repo.full_name,ref:.head.ref,sha:.head.sha},base:{repo:.base.repo.full_name,ref:.base.ref,sha:.base.sha}}'
   BASE_REPO="$(gh-axi api repos/<owner>/<repo>/pulls/<number> --jq '.base.repo.full_name')"
   BASE_REF="$(gh-axi api repos/<owner>/<repo>/pulls/<number> --jq '.base.ref')"
   BASE_REMOTE="refs/remotes/pr-base/${BASE_REF}"
   git fetch "https://github.com/${BASE_REPO}.git" "refs/heads/${BASE_REF}:${BASE_REMOTE}"
   ```

   Before a PR exists, derive the intended base from the local branch and fetch
   that base directly.
   For fork or replacement workflows, set
   `TARGET_BASE_REPO` to the intended upstream repository rather than assuming
   `origin`.
   ```sh
   BRANCH="$(git branch --show-current)"
   BASE_REPO="${TARGET_BASE_REPO:-$(gh-axi repo view --json nameWithOwner --jq '.nameWithOwner')}"
   BASE_REF="${TARGET_BASE_REF:-$(git config "branch.${BRANCH}.gh-merge-base" || true)}"
   BASE_REF="${BASE_REF:-$(gh-axi repo view "${BASE_REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name')}"
   BASE_REMOTE="refs/remotes/pr-base/${BASE_REF}"
   git fetch "https://github.com/${BASE_REPO}.git" "refs/heads/${BASE_REF}:${BASE_REMOTE}"
   git status --short
   git branch -vv
   ```
   Use `gh-axi`, not raw `gh`, in this repo.

2. Compare against current base, not the branch's old base.
   ```sh
   git log --oneline --cherry-pick --right-only "${BASE_REMOTE}"...HEAD
   git diff --name-status "${BASE_REMOTE}"...HEAD
   git merge-tree "$(git merge-base "${BASE_REMOTE}" HEAD)" "${BASE_REMOTE}" HEAD
   ```
   If the branch is dirty/conflicting, rebase or rebuild before asking anyone to
   review or merge it.

3. Check overlap and supersession.
   - Inspect recently merged commits on `${BASE_REMOTE}`.
   - Inspect adjacent open PRs that touch the same files or subsystem.
   - Decide whether the change is still needed, partly superseded, or should be
     split into smaller PRs.

4. Verify the change.
   - Run focused tests for the changed behavior.
   - Run lint/syntax checks for touched languages.
   - For code changes in firstmate, run the no-mistakes gate once the work is
     committed unless the user explicitly chooses a lighter path.
   - Do not claim GitHub CI passed unless GitHub actually shows passing checks.

5. Inspect public text.
   Remove local/internal language before opening, updating, or commenting:
   - no "Captain" address;
   - no local transcript/intake details;
   - no firstmate operational chatter unless it is relevant to the upstream repo;
   - no "validated locally" claim without the exact commands and outcome;
   - no request to merge a conflicting, stale, or unverified branch.

## Maintainer-facing format

Prefer this structure:

```markdown
## What

One short paragraph describing the bug or capability.

## Why

The concrete failure mode or maintainer-relevant motivation.

## Changes

- Specific implementation points.
- Any deliberate scope limits.

## Validation

- `command` - outcome
- GitHub checks: passed / unavailable with reason

## Notes

Compatibility, risk, or follow-up work if relevant.
```

For replacement PRs from a fork, also state what happened to the original PR:

```markdown
This is a rebased/reworked replacement for #<old>.
I kept <specific useful part>, dropped <superseded part>, and retested against current base.
```

## Stop conditions

Do not proceed publicly without telling the captain if any of these are true:

- GitHub reports `mergeable=false`, `mergeable_state=dirty`, or not rebaseable.
- The PR has no GitHub checks and the repo normally expects checks.
- The PR body still contains internal transcript language.
- The branch includes unrelated fixes that should be split.
- Recent upstream commits may have already solved the same problem.
