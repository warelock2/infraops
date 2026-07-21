# Git Workflow

## Normal Development Workflow

### 1. Create a Feature Branch

    git checkout master
    git pull
    git checkout -b feature/add-worker-pool

### 2. Make Changes

    # edit infrastructure.yaml or playbooks
    git add .
    git commit -m "Add worker pool configuration"

### 3. Push and Create PR

    git push origin feature/add-worker-pool

- Create PR in Forgejo
- CI runs validation (terraform plan, ansible --check, schema validation)
- Reviewer sees exactly what will change before approving

### 4. Merge PR

- Approve and merge PR to master
- CI runs enforcement (terraform apply, ansible)
- Infrastructure is updated

### 5. Tag a Release

    git tag v1.2.0
    git push origin v1.2.0

- Tag is a snapshot marker, no enforcement triggered
- Serves as versioning and audit trail

## Skipping CI

Push to master with workflows enabled will trigger enforcement. To skip:

    git commit -m "Your message [skip ci]"

This is a universal convention (Forgejo Actions, GitHub Actions, GitLab CI). Use
when pushing directly to master during development or for doc-only changes.

## Rollback Workflow

### Decision Tree

| Situation | Response |
|---|---|
| Last commit broke it | `git revert HEAD` — fastest |
| Don't know which commit | Roll back to last known good tag, investigate offline |
| Found the bad commit | Restore to current with fix via staging reverts |

### 1. Last Commit Broke It (Fastest)

    git revert HEAD
    git push

One commit, done. No rollback to a tag, no investigation needed.

### 2. Don't Know Which Commit (Rollback to Tag)

    git revert --no-commit v1.0..HEAD
    git commit -m "Rollback to v1.0"
    git push

Prod is back up in seconds on v1.0. Investigate offline while prod is stable.

### 3. Find the Bad Commit

    git log --oneline v1.0..HEAD

Or use bisect:

    git bisect start
    git bisect bad HEAD
    git bisect good v1.0
    # test at each step
    git bisect reset

### 4. Restore to v2.0 with Fix (Skip Bad Commit)

    git revert --no-commit HEAD~1
    git revert --no-commit <bad-commit>
    git commit -m "Restore v2.0, skip <bad-commit> (<reason>)"
    git push

One atomic commit. Bad commit never takes effect. Prod goes from v1.0 to
v2.0-with-fix in a single step.

## Quick Reference

| Goal | Command |
|---|---|
| Rollback to v1.0 | `git revert --no-commit v1.0..HEAD && git commit -m "Rollback to v1.0"` |
| Restore to v2.0 | `git revert --no-commit HEAD~1 && git commit -m "Restore to v2.0"` |
| Skip bad commit | `git revert --no-commit HEAD~1 && git revert --no-commit <bad> && git commit -m "Restore v2.0, skip <bad>"` |
| Undo a single commit | `git revert <hash>` |
| Undo a revert | `git revert HEAD` |
