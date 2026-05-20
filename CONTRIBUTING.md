# Contributing to dt-pilot

Thanks for your interest in improving dt-pilot. This document describes the
contribution workflow that humans **and** AI agents are expected to follow.

## Ground rules

- **Never commit directly to `main`.** Every change — even one-line typo fixes —
  goes through a feature branch and a pull request. See
  [`docs/BRANCH-WORKFLOW.md`](docs/BRANCH-WORKFLOW.md).
- **Squash-merge only.** Preserve the linear history on `main`. The PR title
  becomes the merge commit subject; write it accordingly.
- **One concern per PR.** Reviewers should be able to hold the diff in their head.
  Reflected catalog regenerations are the exception (always large and mechanical).
- **No secrets in the repo.** Auth tokens, OAuth client secrets, environment URLs
  with tenant IDs — all live in environment variables or developer-local files
  that `.gitignore` covers.

## Branch naming

Use [Conventional Commits](https://www.conventionalcommits.org/) style prefixes:

| Prefix | Use for |
|---|---|
| `feat/<scope>` | A new capability (script, doc, example, config type) |
| `fix/<scope>` | A bug fix |
| `chore/<scope>` | Tooling, repo meta, CI plumbing without behavior change |
| `docs/<scope>` | Documentation-only changes |
| `refactor/<scope>` | Internal restructuring with no behavior change |
| `test/<scope>` | Test-only changes |

Examples:
- `feat/monaco-dry-run-wrapper`
- `fix/manifest-schema-required-fields`
- `chore/ci-pin-monaco-version`
- `docs/dql-primer`

## Commit messages

Write each commit's subject (header) in [Conventional Commits](https://www.conventionalcommits.org/) form. The body is free-form prose explaining the *why*, not a continuation of the `<type>(<scope>):` pattern:

```
<type>(<optional scope>): <short imperative summary>

<optional longer body explaining the why, not the what>
```

## Local quality gate

> **Planned (PR&nbsp;6):** `scripts/Pre-Commit.ps1` and the Pester suite under
> `tests/` are introduced together in a later PR. Until that PR has merged,
> there is no local quality gate beyond standard `git` checks, so until then
> the steps below are aspirational rather than enforceable.

Once the gate has landed, before pushing run:

```powershell
./scripts/Pre-Commit.ps1
```

This script will run manifest schema validation, Monaco dry-run against any
committed example projects, MCP secret-hygiene checks, and the Pester test
suite. CI will run the same gate; running it locally avoids round-trip red
builds.

## PR workflow

1. Branch from `main` using the appropriate prefix from the [Branch naming](#branch-naming) table (e.g. `feat/<scope>`, `fix/<scope>`, `chore/<scope>`, `docs/<scope>`): `git checkout -b <type>/<scope>`.
2. Make focused changes.
3. Run `./scripts/Pre-Commit.ps1` (once it has landed in PR&nbsp;6) and fix anything it surfaces.
4. Push the branch and open a PR with the project's PR template.
5. Wait for CI green (once CI has landed in PR&nbsp;6); address review comments.
6. Squash-merge the PR; delete the branch.

## Code style

- **PowerShell:** scripts target PowerShell 7+. Use approved verbs (`Get-`,
  `Invoke-`, `Test-`, `Set-`, `New-`, `Sync-`). Use `[CmdletBinding()]` and
  `param(...)` blocks. The named wrappers below are **planned**; they land
  across PRs 4–8. Once they exist, follow the `-Path` convention they
  encode: wrappers that operate on a specific Monaco manifest or project
  (the `Invoke-Monaco*` family, `Validate-Monaco.ps1`,
  `Initialize-MonacoWorkspace.ps1`, `Test-MonacoManifest.ps1`) take an
  explicit `-Path` parameter — always pass it, do not rely on the caller's
  `$PWD`. Repo-wide gates (`Pre-Commit.ps1`, `Get-MonacoVersion.ps1`,
  `Sync-ConfigCatalog.ps1` default mode, `Test-McpConfigSecrets.ps1`)
  intentionally operate on the repository root and do not take `-Path`.
- **YAML:** 2-space indentation, no tabs, LF line endings, UTF-8 without BOM.
- **Markdown:** wrap prose at ~100 chars when practical; tables are fine.

## Reporting issues

Open a GitHub issue with:
- A short title in `[area] summary` form (e.g. `[scripts] Invoke-MonacoDeploy refuses valid dry-run file`).
- A minimal reproduction.
- What you expected vs what happened.
- Monaco version, PowerShell version, OS.
