# GitHub Copilot Instructions — dt-pilot

This file is the GitHub Copilot counterpart to [`../CLAUDE.md`](../CLAUDE.md). When the two ever diverge, **`CLAUDE.md` is canonical** — open a `chore/sync-instructions` PR to bring this file back in sync.

This workspace is a Dynatrace configuration-as-code harness built on the **Monaco** CLI ([Dynatrace/dynatrace-configuration-as-code](https://github.com/Dynatrace/dynatrace-configuration-as-code)).

## Read Before Editing

1. [`skills/dynatrace/SKILL.md`](../skills/dynatrace/SKILL.md) — canonical Monaco + DQL reference *(lands in PR&nbsp;3)*.
2. [`docs/BRANCH-WORKFLOW.md`](../docs/BRANCH-WORKFLOW.md) — branch naming + squash-merge policy + Copilot review loop.

## Non-Negotiable Rules (mirror of `CLAUDE.md` "Key Rules")

- **Never commit to `main`.** Every change goes via a `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, or `test/` branch and is squash-merged via a PR.
- **PRs request Copilot review.** After opening, `gh pr edit <num> --add-reviewer @copilot`. Address every inline comment. Resolve every thread via the `resolveReviewThread` GraphQL mutation. Then squash-merge.
- **`monaco deploy` requires a saved dry-run file.** Use `Invoke-MonacoDryRun.ps1` → present summary → wait for user approval → `Invoke-MonacoDeploy.ps1 -DryRunFile ...`.
- **`monaco delete` requires both a curated deletefile and an explicit `-Confirm` flag.** Use `Invoke-MonacoGenerate.ps1 -Type deletefile` to produce the deletefile; review it; then `Invoke-MonacoDelete.ps1 -Confirm`.
- **No secrets in committed files.** Auth lives in environment variables (`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `DT_PLATFORM_TOKEN`, `DT_ENVIRONMENT`). MCP per-developer overrides live in `.vscode/mcp.session.json` (gitignored).
- **Use the wrapper scripts in `scripts/`** (introduced in PR&nbsp;4) instead of typing `monaco` commands directly.
- **Use the Dynatrace MCP server** (`@dynatrace-oss/dynatrace-mcp-server`, configured in PR&nbsp;5) for DQL generation/verification, entity lookup, problem/vulnerability discovery, and Davis Copilot — instead of guessing.
- **Never hand-edit generated files** under `modules/configs/` (PR&nbsp;8). Regenerate via `Sync-ConfigCatalog.ps1`.

## Code Style

- **YAML:** 2-space indentation, no tabs, LF line endings, UTF-8 without BOM.
- **JSON templates:** 2-space indentation. Keep `{{ .parameter }}` placeholders close to the parameter definitions in the sibling `.yaml`.
- **PowerShell scripts:** target PowerShell 7+. Approved verbs (`Get-`, `Invoke-`, `Test-`, `Set-`, `New-`, `Sync-`). `[CmdletBinding()]` + `param(...)` always. Explicit `-Path` parameter, never reliance on `$PWD`.
- **Markdown:** wrap at ~100 chars where practical.

## PR Workflow (concise)

```powershell
git checkout -b <type>/<scope>
# ... edits ...
./scripts/Pre-Commit.ps1            # lands in PR 6
git commit -m "<type>(<scope>): <summary>"
git push -u origin <type>/<scope>
gh pr create --fill
gh pr edit <num> --add-reviewer "@copilot"
# wait for Copilot review; address comments; resolve threads
gh pr merge <num> --squash --delete-branch
```

See [`docs/BRANCH-WORKFLOW.md`](../docs/BRANCH-WORKFLOW.md) for the full ceremony.

## When in Doubt

- **DQL syntax:** use the Dynatrace MCP `verify_dql` / `generate_dql_from_natural_language` tools.
- **Settings 2.0 schema:** use Monaco's `monaco generate schema` (wrapped by `Invoke-MonacoGenerate.ps1 -Type schema`) or cross-reference [`docs.dynatrace.com`](https://docs.dynatrace.com).
- **Anything else:** consult `CLAUDE.md` first — it has more detail than this file by design.
