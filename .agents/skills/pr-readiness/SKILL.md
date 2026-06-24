---
name: pr-readiness
description: Prepare, audit, or rewrite a pull request before it is opened, updated, commented on, or presented to a maintainer. Use when a user asks to create a PR, ask someone to merge a PR, replace an upstream PR from a fork, comment on a PR, publish branch work, or make sure a PR is maintainer-ready.
---

# pr-readiness

Use this before any public PR action: opening a PR, updating a PR body, asking a
maintainer to merge, commenting with a replacement branch, or presenting a PR as
ready. The goal is to avoid wasting maintainer attention with stale branches,
missing research, internal transcript language, or weak validation.

## Required checks

1. Refresh the base and PR facts.
   ```sh
   git fetch origin main
   gh-axi pr view <number> --json number,title,author,mergeStateStatus,statusCheckRollup,changedFiles,additions,deletions,url
   gh-axi api repos/<owner>/<repo>/pulls/<number> --jq '{mergeable,mergeable_state,rebaseable,head:{repo:.head.repo.full_name,ref:.head.ref,sha:.head.sha},base:{ref:.base.ref,sha:.base.sha}}'
   ```
   Use `gh-axi`, not raw `gh`, in this repo.

2. Compare against current base, not the branch's old base.
   ```sh
   git log --oneline --cherry-pick --right-only origin/main...HEAD
   git diff --name-status origin/main...HEAD
   git merge-tree "$(git merge-base origin/main HEAD)" origin/main HEAD
   ```
   If the branch is dirty/conflicting, rebase or rebuild before asking anyone to
   review or merge it.

3. Check overlap and supersession.
   - Inspect recently merged commits on `origin/main`.
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
This is a rebased/reworked replacement for #<old>. I kept <specific useful
part>, dropped <superseded part>, and retested against current `main`.
```

## Stop conditions

Do not proceed publicly without telling the captain if any of these are true:

- GitHub reports `mergeable=false`, `mergeable_state=dirty`, or not rebaseable.
- The PR has no GitHub checks and the repo normally expects checks.
- The PR body still contains internal transcript language.
- The branch includes unrelated fixes that should be split.
- Recent upstream commits may have already solved the same problem.
