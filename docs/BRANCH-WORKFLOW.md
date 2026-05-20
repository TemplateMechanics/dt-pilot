# Branch and Merge Workflow

dt-pilot uses a strict trunk-based workflow. The rules below apply equally to
human contributors and AI agents driving the repo through Claude Code, Copilot,
or any other harness.

## The non-negotiables

1. **Never commit directly to `main`.** Not even bootstrap commits, typo fixes,
   or "this is obviously safe" changes. The repo was built end-to-end on its
   own PR workflow; that property has to hold from the very first commit.
2. **Every change goes via a semantic branch and a squash-merged PR.** No merge
   commits, no rebase-and-merge — squash only, so `main`'s history is one
   commit per logical change.
3. **One concern per PR.** Reflected catalog regenerations are the only
   permitted exception (they're large and mechanical by design).

## Branch naming

Use Conventional Commits style prefixes:

| Prefix | Use for |
|---|---|
| `feat/<scope>` | A new capability |
| `fix/<scope>` | A bug fix |
| `chore/<scope>` | Tooling, repo meta, CI plumbing without behavior change |
| `docs/<scope>` | Documentation-only changes |
| `refactor/<scope>` | Internal restructuring with no behavior change |
| `test/<scope>` | Test-only changes |

The `<scope>` is short, kebab-cased, and identifies the area touched (script
name, doc area, config type). Examples:

- `feat/monaco-dry-run-wrapper`
- `fix/manifest-schema-required-fields`
- `chore/ci-pin-monaco-version`
- `docs/dql-primer`

## PR title format

The PR title becomes the squash-merge commit subject. Write it as a
Conventional Commit:

```
<type>(<optional scope>): <short imperative summary>
```

Good:
- `feat(scripts): add Invoke-MonacoDelete wrapper with deletefile guard`
- `fix(ci): pin Monaco to 2.18 in validate workflow`
- `docs(skill): document Grail bucket selection in DQL primer`

Avoid:
- `Update stuff`
- `WIP`
- `Fix the bug we talked about`

## The lifecycle of a change

```text
main
 |
 |--+ feat/my-change       <- branch from main
 |  |
 |  o  commit              <- focused, small, conventional commit message
 |  o  commit
 |  |
 |  o  push                <- opens PR via gh pr create
 |  |
 |  | CI runs validate workflow
 |  | reviewer (or autonomous loop) approves
 |  |
 |<-+ squash-merge         <- one commit lands on main
 |    delete branch
 o
```

CLI shorthand:

```powershell
git checkout -b feat/my-change
# ... edits ...
./scripts/Pre-Commit.ps1
git add -A
git commit -m "feat(scope): short summary"
git push -u origin feat/my-change
gh pr create --fill
# ... after CI green ...
gh pr merge --squash --delete-branch
```

## Agent obligations

Any AI agent working in this repo must:

- Read this file before its first push.
- Never invoke `git push origin main` or `git commit` on `main`.
- Run `./scripts/Pre-Commit.ps1` before pushing.
- Open a PR via `gh pr create` and wait for CI green before merging.
- Use `gh pr merge --squash --delete-branch` (never `--merge`, never `--rebase`).
- If the user requests a destructive operation (deletefile, force-push to a
  shared branch, anything affecting the live Dynatrace environment), surface
  it for explicit confirmation rather than proceeding silently.

## Hot-fix policy

There is no hot-fix shortcut around the PR gate. Production incidents in a
consuming project use the consuming project's incident process; dt-pilot itself
is harness code and does not require sub-PR-latency fixes.

## Why this is strict

Two reasons:

1. **Reproducibility.** Trunk-based, squash-merged history is trivial to
   bisect, blame, and revert. Every change has exactly one commit on `main`,
   with a description of why it landed.
2. **Agent safety.** AI agents are powerful enough to land a 50-file change in
   five minutes. The PR gate forces a review surface — even if the reviewer is
   another agent or a CI workflow — between authorship and the trunk.
