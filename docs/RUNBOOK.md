# Runbook

Operational runbook for dt-pilot. Each entry is a symptom you can grep for, followed by triage and recovery steps. Severity tags follow the convention in the [`agents/chief-systems-engineer.agent.md`](../agents/chief-systems-engineer.agent.md) playbook.

---

## [SEV-1] Production deploy applied changes that weren't in the dry-run

**Symptom:** A `monaco deploy` against `prod` modified configs the dry-run summary didn't list, OR the user's reviewed dry-run summary doesn't match what landed.

**Triage:**

1. Stop. Capture the running deploy log if it's still active.
2. Inspect the dry-run artifact: `Get-Content dryrun/prod.json | ConvertFrom-Json | Format-List`. Verify `manifestSha256` and `workspaceHash` match the commit you intended.
3. If `Invoke-MonacoDeploy.ps1`'s freshness/hash checks were bypassed (e.g. someone hand-edited the artifact), open a SEV-1 incident — the harness was deliberately circumvented.

**Recovery:**

- For an unintended config change, run `./scripts/Invoke-MonacoDownload.ps1 -Path . -Environment <env> -Output downloaded/<env>` to snapshot the current state, diff against the pre-deploy commit, and prepare a revert PR through normal review.
- For an unintended delete, restore from the most recent download snapshot or from Dynatrace's per-config version history (settings 2.0 keeps revisions).
- **Post-mortem must answer:** how did the deploy run without an unmodified, fresh, matching dry-run? `Invoke-MonacoDeploy.ps1` is the single chokepoint — the answer is either a bug in the wrapper (file a fix-forward issue) or a process bypass (file a process-control issue).

---

## [SEV-2] `Invoke-MonacoDeploy.ps1` reports `workspaceHash mismatch`

**Symptom:** Deploy refuses to run; error contains `workspaceHash mismatch`.

**Triage:** Expected behavior, not a bug. The hash check fires when any file under any project directory referenced by the manifest was modified after the dry-run artifact was produced.

**Recovery:**

1. Re-run `Invoke-MonacoDryRun.ps1` against the current workspace.
2. Re-review the new dry-run summary — the change you just made may affect different configs than the original dry-run.
3. Deploy from the new artifact.

If you're sure nothing material changed (e.g. only whitespace or comment edits): re-dry-run anyway. The cost is small; the cost of deploying unreviewed content is unbounded.

---

## [SEV-2] `Invoke-MonacoDeploy.ps1` reports stale dry-run (>30 minutes)

**Symptom:** `Dry-run artifact is N minute(s) old; the maximum permitted age is 30 minute(s).`

**Triage:** Drift protection working as intended.

**Recovery:** Re-run `Invoke-MonacoDryRun.ps1`. If you genuinely need a longer review window for a coordinated deploy, pass `-MaxAgeMinutes <N>` *and* document the reason in the deploy PR.

---

## [SEV-2] Dynatrace MCP server fails to start in VS Code

**Symptom:** The MCP icon in VS Code / Claude Code shows the `dynatrace` server as failed; agent can't call DQL tools.

**Triage:**

1. Run `./scripts/Test-DynatraceMcpReadiness.ps1`. It gives one targeted error per issue (Node missing, env missing, catalog corrupt).
2. Check VS Code's MCP output channel for the launcher's stderr — `Start-DynatraceMcpServer.ps1` always writes diagnostics there.
3. Verify the auth env (one of: `DT_PLATFORM_TOKEN`, or both `OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET`) is set in the *shell that launched VS Code*, not just a different terminal.

**Recovery:** Fix the underlying issue from step 1; reload the workspace.

---

## [SEV-3] Manifest schema check fails in pre-commit

**Symptom:** `./scripts/Pre-Commit.ps1` reports a failure under "Manifest schema check".

**Triage:** `Test-MonacoManifest.ps1` flagged a missing required field (`manifestVersion` / `projects` / `environmentGroups`), a project name with no on-disk directory, an inline literal URL, or an inline secret value in an auth block.

**Recovery:** The error message names the file and line. The most common fixes:

- Missing `manifestVersion: 1.0` → add it.
- Project referenced but directory missing → either create the directory or remove the project entry.
- Literal URL in `value:` → switch to `type: environment` with an env-var name.
- Inline `value:` under `token:` / `platformToken:` / `clientId:` / `clientSecret:` → switch to `name: <ENV_VAR_NAME>`.

---

## [SEV-3] MCP secret-hygiene scan fails (`Test-McpConfigSecrets.ps1`)

**Symptom:** `Pre-Commit.ps1` reports a finding under "MCP secret-hygiene scan" — a Dynatrace token literal, live tenant URL, or credential-embedded URL in a committed (or staged) MCP config.

**Recovery:**

1. Remove the offending value from the committed file.
2. If you need that value for your own dev session, put it in `.vscode/mcp.session.json` (gitignored) generated via `New-McpSessionConfig.ps1`, or in your shell env.
3. Re-stage and re-run the gate.

---

## [SEV-3] Monaco rejects a `monaco delete` invocation

**Symptom:** The `Invoke-MonacoDelete.ps1` wrapper refuses to run.

**Triage:** Two intentional refusals:

- `-Confirm` not specified → re-invoke with `-Confirm`.
- `-DeleteFile` points at a non-existent file → generate one with `Invoke-MonacoGenerate.ps1 -Path . -Type deletefile` and prune to the subset you want to remove.

Delete is irreversible at the Dynatrace platform layer for many config types. The double-gate (deletefile + `-Confirm`) is the harness's primary defense against an over-broad deletion.

---

## [SEV-4] Reflected catalog sync check fails in CI

**Symptom:** *(applies once PR&nbsp;8 lands the reflected catalog)* `Sync-ConfigCatalog.ps1 -Check` fails in the validate workflow with "generated output is stale".

**Recovery:**

1. Locally: `./scripts/Sync-ConfigCatalog.ps1` (no `-Check`) to regenerate.
2. Commit the regenerated files in the same PR.
3. Re-push.

Never hand-edit files under `modules/configs/`. Fix the catalog (`config/catalog/`) or the generator instead, then regenerate.

---

## Reporting a new failure mode

If you hit a symptom not covered here, add an entry to this runbook in the same PR that introduces the fix. Each entry should have: **severity**, **symptom**, **triage steps**, and **recovery steps**. Keep entries short — one screenful per entry is the target.
