# Skill — The dt-pilot IaC contract

This is the **tool-agnostic** harness contract every backend implements. Per-backend skills (`skills/dynatrace/SKILL.md` for Monaco, `skills/terraform/SKILL.md` for the future Terraform backend, etc.) cover backend-specific syntax; this skill covers the rules every backend must satisfy regardless of which one you're using.

Read this skill before reading any per-backend skill. The per-backend skills assume you already know the contract.

---

## 1. The contract in one paragraph

Every dt-pilot backend (Monaco today; Terraform, Crossplane, Pulumi planned) ships with three primary operations: **plan**, **apply**, and **destroy**. The plan produces a saved, reviewable artifact. Apply requires that artifact and refuses to run if it's stale, missing, or doesn't match the live workspace. Destroy requires an explicit `-Confirm` and, where the backend supports it, an explicit list of resources to remove. Read-only discovery goes through MCP before any backend-specific CLI. Secrets live in environment variables, never in committed files. Every change goes via a semantic branch + Copilot-reviewed + squash-merged PR, never directly to `main`.

The next sections expand each requirement.

---

## 2. Plan as a reviewable artifact

Every backend's "what would happen" command writes a **persisted artifact** to disk. The artifact is the unit of human review; it travels from the dry-run step into the apply step.

The artifact carries at minimum:

- **Backend identifier** (`monaco`, `terraform`, etc.) so a wrong-backend invocation fails fast.
- **Target environment** so an artifact intended for `dev` cannot be replayed against `prod`.
- **Source-content hash** over every input file the backend would read at apply time (manifest + project files for Monaco; `*.tf` + `*.tfvars` + lockfile for Terraform). The hash binds the artifact to a specific workspace state.
- **Timestamp** so apply can reject artifacts older than a configured freshness window.
- **Operation summary** — counts of creates / updates / deletes plus the raw underlying output for human review.

Concrete artifact schemas:

| Backend | Schema identifier | File shape |
|---|---|---|
| Monaco | `dt-pilot.dryrun/v1` | `dryrun/<env>.json` |
| Terraform *(planned, design 003)* | `dt-pilot.tfplan/v1` | `tfplan` (binary) + `dryrun/<env>.json` (envelope) |

Backends extending the contract add their own schema identifier; the envelope shape is consistent.

---

## 3. Apply requires a saved plan

Every backend's apply wrapper has a `-DryRunFile` / `-PlanFile` parameter that is **mandatory**. The wrapper refuses to run if the parameter is missing or the file does not exist.

Beyond presence, the wrapper enforces four independent checks before invoking the backend's apply primitive:

1. **Schema match.** The artifact's schema identifier matches the wrapper's expectation. Hand-edited or wrong-backend artifacts are rejected.
2. **Environment match.** The artifact's environment matches the `-Environment` parameter. An artifact produced for `dev` cannot be replayed against `prod`.
3. **Workspace-content hash match.** The hash recorded in the artifact matches the current on-disk hash of every input file. An edit to ANY input after the plan invalidates the apply.
4. **Freshness.** The artifact is no older than `-MaxAgeMinutes` (default 30). Stale plans are rejected to prevent applying decisions that no longer reflect the live target environment.

These are **consistency checks, not cryptographic integrity proof**. The artifact is unsigned JSON. The checks defend against honest drift (post-plan edits, environment swaps, stale reviews); they do not defend against an adversarial author who edits the artifact to satisfy them.

The wrapper invokes the backend's apply primitive only after every check passes. There is no `--force` to bypass a check; there is no environment variable that disables the check. If you need a longer review window for a coordinated deploy, pass `-MaxAgeMinutes <N>` explicitly and document the reason in the deploy PR.

---

## 4. Destroy is double-gated

Every backend's destroy wrapper requires both:

- An explicit **`-Confirm`** parameter (a switch, not a boolean — mandatory, must appear in the invocation).
- Where the backend supports a targeted-resource list (Monaco's deletefile, Terraform's targeted destroy plan), an explicit path to that list as a separate parameter.

The wrapper echoes the resource list to the operator before invoking destroy, so the operator has one last chance to abort by Ctrl-C.

The agent persona for each backend (`agents/<backend>.agent.md`) additionally requires explicit destroy authorization in the chat conversation before invoking the wrapper. That authorization is conversational discipline, not enforceable in code — but the `-Confirm` gate is.

---

## 5. Reads go through MCP first

Read-only discovery — "what entities exist?", "what's the current value of this setting?", "what problems are open?", "what does this DQL query return?" — uses the **Dynatrace MCP server** before any backend CLI. The MCP server is the same regardless of which backend a workspace uses; it sits in front of the platform, not in front of any particular tool.

Specifically:

- Use MCP `find_entity_by_name`, `execute_dql`, `verify_dql`, `generate_dql_from_natural_language`, `list_problems`, `list_vulnerabilities`, `chat_with_davis_copilot` for discovery.
- Use backend-specific commands (`monaco generate schema`, `terraform providers schema`) only when MCP cannot answer the question (e.g. you need the raw JSON Schema for a settings 2.0 type).

If the workspace's MCP integration is misconfigured, the harness has standard troubleshooting: see [`docs/MCP-INTEGRATION.md`](../../docs/MCP-INTEGRATION.md) and `scripts/Test-DynatraceMcpReadiness.ps1`.

---

## 6. Secrets are environment variables, never committed

The repository contains no Dynatrace tokens, OAuth secrets, tenant URLs that identify a customer, or other operator credentials. Every backend's wrappers and every backend's committed configuration resolve credentials at runtime from environment variables.

The canonical environment variables — set once by the developer or CI, used by every backend — are:

- `DT_ENVIRONMENT` — the Dynatrace platform URL.
- `DT_PLATFORM_TOKEN` — a platform token (preferred for local dev and read-only paths).
- `OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET` — OAuth client credentials (preferred for CI and account-management operations).

Backends whose underlying CLI expects different variable names are responsible for translating internally — the user always sets the canonical names. See [`docs/AUTHENTICATION.md`](../../docs/AUTHENTICATION.md) for the per-backend mapping and provisioning walkthrough.

Per-developer MCP overrides live in `.vscode/mcp.session.json` (gitignored). The pre-commit gate runs `scripts/Test-McpConfigSecrets.ps1 -StagedOnly` and blocks any commit that includes a token literal, live tenant URL, or credential embedded in a URL inside a committed MCP config file. Backend-specific committed files (Monaco's `manifest.yaml`, Terraform's `*.tf`) get the same secret-hygiene treatment by their per-backend manifest validators.

---

## 7. Branch and PR discipline

Every change — human or agent — goes via a semantic branch and a squash-merged GitHub PR. **`main` is never committed to directly.** Prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, `test/`. PR titles follow Conventional Commits.

After opening a PR, the author (or the agent acting on behalf of the author) requests Copilot code review via `gh pr edit <num> --add-reviewer @copilot`, addresses every inline comment, resolves every review thread via the `resolveReviewThread` GraphQL mutation, and only then squash-merges via `gh pr merge --squash --delete-branch`.

See [`docs/BRANCH-WORKFLOW.md`](../../docs/BRANCH-WORKFLOW.md) for the full ceremony.

---

## 8. Backend routing

The active backend (or backends) in a workspace is determined by **workspace shape**, not by chat preamble or per-repo config. The router rule lives in [`CLAUDE.md`](../../CLAUDE.md) "Backend Routing" — read that section first when you encounter an unfamiliar workspace. If multiple backends apply (Monaco AND Terraform on the same Dynatrace tenant is the common case), read every applicable per-backend skill.

`config/catalog/backends.json` is the authoritative registry of supported backends. It records each backend's skill path, scripts directory, catalog file, modules directory, manifest pattern, and detection rules. Tools (`Pre-Commit.ps1`, future `Sync-McpServerEnablement.ps1`) read this file rather than hard-coding paths.

---

## 9. Adding a new backend

The mechanical steps:

1. **Author the per-backend skill** at `skills/<backend>/SKILL.md`. Defer to this iac skill for the contract; cover backend-specific syntax, schemas, and idioms.
2. **Author the per-backend wrappers** under `scripts/<backend>/`. At minimum: `Initialize-<Backend>Workspace.ps1`, `Validate-<Backend>.ps1`, `Invoke-<Backend>Plan.ps1`, `Invoke-<Backend>Apply.ps1`, `Invoke-<Backend>Destroy.ps1`, `Get-<Backend>Version.ps1`, and (if the backend carries a reflected catalog) `Sync-<Backend>Catalog.ps1`. Each per-manifest wrapper takes an explicit `-Path` parameter; repo-wide wrappers do not.
3. **Author a per-backend agent persona** at `agents/<backend>.agent.md`. Mirror the structure of `agents/dynatrace.agent.md`.
4. **Add an entry to** `config/catalog/backends.json`. Run the schema check (covered by the pre-commit gate). Add any required catalog file under `config/catalog/<backend>.json` with its own schema sibling if the backend ships a reflected catalog.
5. **Add the detection rule to** the Backend Routing section in `CLAUDE.md`.
6. **Add Pester tests** under `tests/` covering every wrapper rejection path. Tests must be hermetic (no live backend invocation, no real credentials).
7. **Add an example project** under `examples/<backend>-baseline/` that exercises the end-to-end flow.
8. **Update** `docs/AUTHENTICATION.md` with the backend's credential mapping.

A new backend should land in a single bounded PR, not a multi-PR series. If the PR is too large to review cleanly, split by capability (skill+wrappers in one PR, catalog+modules in a follow-up) rather than by file type.

---

## 10. What backends explicitly DO NOT share

To prevent over-abstraction:

- **State files.** Monaco is stateless against the live API; Terraform has a state file; Crossplane stores state in Kubernetes etcd; Pulumi has its own state model. Each backend's per-backend skill covers its state model; this skill does not pretend they're uniform.
- **Plan formats.** The envelope is consistent (schema id, env, hash, summary), but the underlying plan content (Monaco's `would create/update/delete` lines vs Terraform's `tfplan` binary vs Pulumi's preview JSON) is backend-specific.
- **Refactor mechanisms.** Monaco's "move a config to a new ID" is two PRs (download under new id, delete old). Terraform has `moved {}` blocks. Crossplane has Composition revisions. Pulumi has `import`/`alias`. Per-backend skill covers; this skill does not.
- **Cross-backend orchestration.** A change that touches Monaco AND Terraform deploys atomically as a single transaction is **not** supported. Each backend's apply runs independently; the operator coordinates ordering via PR sequencing.

---

## 11. When the contract conflicts with backend behavior

If a backend's natural behavior conflicts with the contract (e.g. a backend has no plan-apply separation, or its destroy has no targeted-list option), one of two things must happen:

1. **The wrapper synthesizes the missing primitive.** Example: Crossplane's `apply` is the only mutation; the dt-pilot Crossplane wrapper synthesizes "plan" by rendering the Composition output and computing diffs locally, then refuses apply without that saved render.
2. **The proposal documents the gap.** If the wrapper cannot reasonably synthesize the missing primitive, the per-backend design proposal documents the limitation in its Non-goals section, the per-backend skill documents the operator's responsibility, and the per-backend agent persona refuses operations the contract requires but the wrapper cannot guarantee.

The contract is not negotiable, but it is implementable. If a backend's design forces a hard incompatibility, that's grounds to reject adding the backend to dt-pilot.
