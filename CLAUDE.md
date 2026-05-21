# Dynatrace Workspace — Claude Code Instructions

This workspace contains Dynatrace configuration-as-code managed by the **Monaco** CLI ([Dynatrace/dynatrace-configuration-as-code](https://github.com/Dynatrace/dynatrace-configuration-as-code)). You are working with:

- **`manifest.yaml`** — the top-level deployment manifest naming projects, environments, and environment groups
- **`*.yaml`** config files under `projects/<project>/<api>/` defining configuration parameters
- **`*.json`** payload templates referenced by those YAML configs (with `{{ .parameter }}` placeholders)
- **`deletefile.yaml`** — generated via `monaco generate deletefile`, lists configs that `monaco delete` will remove
- **OAuth client credentials** or a **platform token** read from environment variables (`OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` / `DT_PLATFORM_TOKEN` / `DT_ENVIRONMENT`) — never from checked-in files

## Before Making Any Edits

Read `skills/dynatrace/SKILL.md` *(planned, lands in PR&nbsp;3)* — it contains the canonical reference for Monaco's project layout, manifest semantics, parameter and dependency syntax, the deploy / dry-run / download / delete lifecycle, account management, and common DQL recipes. This is the single source of truth for this project. Until PR&nbsp;3 lands, fall back to the [official Monaco docs](https://docs.dynatrace.com/docs/deliver/configuration-as-code/monaco) and the inline guidance in this file.

Use the official **Dynatrace MCP server** first when available (`@dynatrace-oss/dynatrace-mcp-server`). Prefer MCP for DQL queries, entity discovery, problem and vulnerability listing, and Davis Copilot consultations. Use project scripts for guarded mutation workflows (validate, dry-run, deploy, delete, download).

If MCP is unavailable, continue with repository docs plus `Get-MonacoVersion.ps1` *(planned, PR&nbsp;4 — until then, call `monaco --version` directly)* for the Monaco version baseline, then proceed with the same script-guarded workflow.

When touching reflected catalog modules under `modules/configs/` or `config/catalog/`, read [`docs/CONFIG-COVERAGE.md`](docs/CONFIG-COVERAGE.md) — it is the canonical doctrine for the reflected scaffold shape, sync semantics, and the per-PR coverage verification template.

## Key Rules

1. **YAML uses 2-space indentation** — never tabs in `.yaml` files. JSON templates use 2-space indentation.
2. **`manifestVersion` and Monaco CLI version are distinct concerns.** `manifest.yaml`'s `manifestVersion` field declares the *manifest schema* version (e.g. `"1.0"`) and must match what your installed Monaco supports — it does **not** pin the CLI itself. Pin the `monaco` executable separately, in CI (e.g. by SHA or release tag in the validate workflow) and in local-dev install docs.
3. **Every project listed in `manifest.yaml` must exist** under `projects/<name>/` and contain at least one valid config.
4. **Save `.yaml`/`.json` files as UTF-8 without BOM**, LF line endings.
5. **NEVER edit the Dynatrace environment directly via the UI for configurations that Monaco owns.** Out-of-band UI changes drift away from the manifest and will be silently overwritten on the next `monaco deploy`. If a UI change is genuinely needed, `monaco download` the change back into source first.
6. **NEVER run a real `monaco deploy` (i.e. without `--dry-run`) without first running `Invoke-MonacoDryRun.ps1` and getting explicit user approval of the planned changes.** This is dt-pilot's equivalent of tf-pilot's plan-before-apply rule. The two-step sequence is non-negotiable. (`monaco deploy --dry-run` is *not* a real deploy and is what `Invoke-MonacoDryRun.ps1` and `Validate-Monaco.ps1` wrap — those invocations do not require additional approval.) Do not pass `--auto-deploy` or any non-interactive deploy flag on a real deploy unless the user has explicitly authorized it for this exact run.
7. **NEVER run `monaco delete` (or `Invoke-MonacoDelete.ps1`) without an explicit delete authorization in the conversation AND an explicit `-Confirm` flag.** Delete is irreversible at the Dynatrace platform layer for many config types.
8. **`monaco delete` requires a deletefile.** Generate it via `Invoke-MonacoGenerate.ps1 -Type deletefile`. Review the deletefile before invoking delete. Never reuse an old deletefile if the manifest or projects have changed.
9. **After editing any `.yaml` or `.json` template**, always run `Validate-Monaco.ps1` (which wraps `monaco deploy --dry-run`) before producing a real dry-run for review. This catches structural errors fast.
10. **Refactors that rename a config ID:** Monaco treats the ID as identity. Renaming the config ID will create a new config and orphan the old one. Either (a) `monaco download` the existing config under the new ID, then `monaco delete` the old one in a separate, reviewed PR, or (b) keep the old ID and rename only the file name (which Monaco ignores for identity).
11. **Sensitive data:** secrets come from environment variables (`OAUTH_CLIENT_SECRET`, `DT_PLATFORM_TOKEN`) or a secrets manager — never `.yaml` / `.json` files committed to git. Use Monaco's `{{ .env.MY_SECRET }}` parameter form for environment-variable injection.
12. **Environment URLs are not secrets but they identify a tenant.** Prefer parameterizing them via the manifest's `environments` block and a per-developer `.env` (gitignored) over hardcoding `https://abc12345.apps.dynatrace.com` in committed config.
13. **Environment groups exist for a reason.** When the user says "deploy to dev", verify the manifest's environment group includes only the intended environment. Never deploy to a `prod` group without explicit prod authorization in the conversation.
14. **DQL Q&A goes through MCP first.** The Dynatrace MCP server can `generate_dql_from_natural_language`, `verify_dql`, `execute_dql`, and `explain_dql_in_natural_language`. Use it instead of guessing DQL syntax — Grail's query language has changed significantly across releases.
15. **State of the live environment is a query, not an assumption.** Before deploying a change that depends on existing entities (a host group, a management zone, a tag), use the MCP `find_entity_by_name` tool or `execute_dql` to confirm the entity exists.
16. **`monaco download` snapshots are diff input, not direct edits.** When pulling configuration from a live environment, treat the download as a candidate for review; reconcile against existing committed configs rather than overwriting them wholesale.
17. **Reflected catalog discipline.** Files under `modules/configs/` are generated by `Sync-ConfigCatalog.ps1` and are protected by CI sync checks. Never hand-edit a generated module — fix the catalog or the generator instead, then regenerate.
18. **Branch + PR discipline.** Never commit to `main`. Every change goes on a `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, or `test/` branch and is squash-merged via a GitHub PR. See [`docs/BRANCH-WORKFLOW.md`](docs/BRANCH-WORKFLOW.md).
19. **PRs request Copilot review.** When opening a PR via `gh pr create`, request review from `@copilot` (`gh pr edit <num> --add-reviewer @copilot`), address every inline comment, resolve every thread via `gh api graphql` `resolveReviewThread` mutation, and only then squash-merge.
20. **MCP secret hygiene.** Never commit a `.vscode/mcp.json` that contains a hardcoded token, tenant URL with credentials, or OAuth secret. Per-developer overrides go in `.vscode/mcp.session.json` (gitignored). The pre-commit gate (PR&nbsp;6) enforces this; until then, eyeball it.

## File Locations

- Top-level manifest: `manifest.yaml`
- Project configs: `projects/<project>/<api>/config.yaml` plus a sibling `template.json`
- Account-management projects: `account-projects/<project>/...` (when used)
- Deletefiles (gitignored if generated ad hoc, committed if curated): `deletefile.yaml`, `delete/*.yaml`
- Downloaded snapshots (gitignored): `downloaded/`
- Per-developer env: `.env` (gitignored), see `docs/AUTHENTICATION.md` (lands in PR&nbsp;8)

## Automation Scripts — USE THESE, DON'T REINVENT THEM

PowerShell scripts in `scripts/` (introduced in PR&nbsp;4) are **required tools** for operational tasks. Always use the project scripts instead of typing `monaco` commands directly, building shell pipelines, or invoking `Start-Process monaco`.

Use these scripts as the execution path after MCP-guided analysis.

| Task | Script | Example |
|------|--------|---------|
| **Init / sanity check** the workspace | `Initialize-MonacoWorkspace.ps1` | `./scripts/Initialize-MonacoWorkspace.ps1 -Path .` |
| **Validate everything** (manifest schema + dry-run) | `Validate-Monaco.ps1` | `./scripts/Validate-Monaco.ps1 -Path .` |
| **Dry-run** changes (writes `dryrun/<env>.json`) | `Invoke-MonacoDryRun.ps1` | `./scripts/Invoke-MonacoDryRun.ps1 -Path . -Environment dev -Out dryrun/dev.json` |
| **Deploy** a reviewed dry-run | `Invoke-MonacoDeploy.ps1` | `./scripts/Invoke-MonacoDeploy.ps1 -Path . -Environment dev -DryRunFile dryrun/dev.json` |
| **Delete** (requires deletefile + `-Confirm`) | `Invoke-MonacoDelete.ps1` | `./scripts/Invoke-MonacoDelete.ps1 -Path . -Environment dev -DeleteFile deletefile.yaml -Confirm` |
| **Generate** a deletefile or schema | `Invoke-MonacoGenerate.ps1` | `./scripts/Invoke-MonacoGenerate.ps1 -Type deletefile -Path .` |
| **Download** live config | `Invoke-MonacoDownload.ps1` | `./scripts/Invoke-MonacoDownload.ps1 -Path . -Environment dev -Output downloaded/` |
| **Print Monaco + provider versions** | `Get-MonacoVersion.ps1` | `./scripts/Get-MonacoVersion.ps1` |
| **Pre-push gate** (manifest schema + dry-run + MCP secret hygiene + tests) | `Pre-Commit.ps1` | `./scripts/Pre-Commit.ps1` |
| **Refresh reflected config catalog** | `Sync-ConfigCatalog.ps1` | `./scripts/Sync-ConfigCatalog.ps1 -Check` |
| **Test manifest YAML against schema** | `Test-MonacoManifest.ps1` | `./scripts/Test-MonacoManifest.ps1 -Path manifest.yaml` |
| **MCP server toggle** | `Set-McpServerState.ps1` | `./scripts/Set-McpServerState.ps1 -Server dynatrace -Enable` |
| **Scan MCP configs for hardcoded secrets** | `Test-McpConfigSecrets.ps1` | `./scripts/Test-McpConfigSecrets.ps1 -StagedOnly` |

> Until PRs 4–6 have landed, those scripts do not exist yet. During that window, you can read this table as the **target** automation surface; if a user explicitly asks you to run one before it has landed, say so and offer to expedite the relevant PR instead.

## Terminal Expectations

- **Assume Windows PowerShell 7+** by default (the cross-platform `pwsh`). The wrapper scripts also run on macOS/Linux pwsh.
- **Execute repo commands from the repository root.** Wrappers that operate on a specific Monaco manifest or project (the `Invoke-Monaco*` family, `Validate-Monaco.ps1`, `Initialize-MonacoWorkspace.ps1`, `Test-MonacoManifest.ps1`) take an explicit `-Path` parameter — always pass it, do not rely on the caller's `$PWD`. Repo-wide gates (`Pre-Commit.ps1`, `Get-MonacoVersion.ps1`, `Sync-ConfigCatalog.ps1` in its default mode, `Test-McpConfigSecrets.ps1`) intentionally operate on the repository root and do not take `-Path`.
- **Avoid Unix shell commands in PowerShell sessions.** `tail`, `uniq`, `grep`, and `sed` are not reliable defaults here and should be replaced with PowerShell equivalents.

### PowerShell equivalents

- `tail -20` → `Select-Object -Last 20`
- `tail -f` → `Get-Content -Wait -Tail 10`
- `grep pattern` → `Select-String pattern`
- `uniq -c` → `Group-Object | Select-Object Count, Name`
- `sed 's/old/new/'` → PowerShell `-replace`

### MANDATORY — the dry-run-before-deploy two-step sequence

> **WARNING**: `monaco deploy` without a saved dry-run file is **forbidden** in this harness. You MUST run BOTH steps every time. Do NOT stop after step 1. Do NOT call deploy without showing the dry-run summary to the user and getting confirmation.

1. **Dry-run** (always first):
   ```powershell
   ./scripts/Invoke-MonacoDryRun.ps1 -Path . -Environment dev -Out dryrun/dev.json
   ```
   The script writes `dryrun/dev.json` containing the planned create/update/delete operations per project and config. Read it, summarize the changes (configs created / updated / deleted, environment, group), and present the summary to the user. Surface every delete and every change to a stateful config (SLOs, alerting profiles, management zones, notification configs).

2. **Deploy** (only after user approval):
   ```powershell
   ./scripts/Invoke-MonacoDeploy.ps1 -Path . -Environment dev -DryRunFile dryrun/dev.json
   ```
   The script refuses to run without `-DryRunFile`. Never pass `--auto-deploy` unless the user said so in this turn.

If 30+ minutes pass between dry-run and deploy, **re-dry-run**. Live environment drift can invalidate a stale dry-run.

### When to use which script:
- **First-time clone, missing `.monaco/` cache, or after editing `manifest.yaml`:** run `Initialize-MonacoWorkspace.ps1`.
- **After any YAML/JSON edit:** run `Validate-Monaco.ps1` first. Fix every error and re-run until clean before producing a real dry-run for review.
- **After modifying a `template.json` parameter shape:** run `Validate-Monaco.ps1`, then dry-run, and pay attention to which existing configs the change touches.
- **Before merging to main:** the CI workflow (`.github/workflows/validate.yml`, lands in PR&nbsp;6) runs the same validator + Pester tests. Run them locally first to avoid red builds.
- **Renaming a config:** see Key Rule 10 — use download/delete/recreate, not in-place rename of the config ID.

## Validation

Always run validation after making changes (once the wrapper has landed):

```powershell
./scripts/Validate-Monaco.ps1 -Path .
```

Exit code is non-zero if the manifest fails schema validation, any `template.json` references an undefined parameter, or `monaco deploy --dry-run` reports an error.

## Provider knowledge boundaries

You DO NOT have reliable knowledge of every Dynatrace settings schema. When in doubt:

1. Read existing `.yaml` / `.json` files in the workspace for working patterns.
2. Use the Dynatrace MCP server (`find_entity_by_name`, `execute_dql`) to confirm the live shape.
3. Cross-check against Dynatrace docs at [docs.dynatrace.com](https://docs.dynatrace.com).

Never invent setting schema IDs. Common hallucination patterns to avoid:

- Mixing `builtin:` settings 2.0 IDs with legacy classic config API endpoints — they have different parameter shapes and live in different Monaco config types.
- Inventing a `scope` value for a settings 2.0 config. Scopes are `environment`, `host`, `host-group`, `process-group`, or a Monitored-Entity ID; never invent free-form strings.
- Using a notification config type (`EMAIL`, `SLACK`, `WEBHOOK`, etc.) without the required type-specific fields. Run dry-run before assuming the shape is correct.
- Assuming a metric / DQL query exists in Grail without verifying via `execute_dql`.

## How a request flows through this agent

1. **Understand** the user's intent (a config change? a query? a deployment? a download?).
2. **Read** `skills/dynatrace/SKILL.md` for any unfamiliar Monaco / DQL syntax.
3. **Locate** relevant files (`manifest.yaml`, `projects/...`).
4. **Discover** live environment context via the Dynatrace MCP server (entities, current settings, DQL).
5. **Create a semantic branch** (`feat/<scope>`).
6. **Edit** Monaco YAML/JSON using repository patterns and the reflected catalog.
7. **Validate** with `Validate-Monaco.ps1`.
8. **Dry-run** with `Invoke-MonacoDryRun.ps1` and present the summary.
9. **Wait for explicit user approval** before deploy.
10. **Deploy** the saved dry-run with `Invoke-MonacoDeploy.ps1`.
11. **Open a PR** with `gh pr create`, request `@copilot` review, address comments, resolve threads, squash-merge.
