# Changelog

All notable changes to dt-pilot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository meta surface: `README`, `LICENSE` (MIT), tuned `.gitignore`, `CONTRIBUTING`, `SECURITY`, `CODE_OF_CONDUCT`, GitHub PR template, and `docs/BRANCH-WORKFLOW.md` codifying the never-commit-to-main + squash-only merge policy.
- Terraform backend ([Design 003](docs/design/TERRAFORM-BACKEND.md)). Adds the second backend behind the multi-backend skeleton from Design 001. Cherry-picks wrapper shapes from [tf-pilot](https://github.com/TemplateMechanics/tf-pilot) and adapts them to dt-pilot's `dt-pilot.tfplan/v1` envelope.
  - `skills/terraform/SKILL.md` + `agents/terraform.agent.md` — defers to `skills/iac/SKILL.md` for the cross-cutting contract; covers `dynatrace-oss/dynatrace` provider specifics.
  - `scripts/terraform/` — `_Common.ps1` (executable resolution, canonical->provider env-var translation, workspace hash, plan-envelope read/write) plus 7 wrappers: `Get-TerraformVersion`, `Initialize-TerraformWorkspace`, `Validate-Terraform`, `Invoke-TerraformPlan`, `Invoke-TerraformApply`, `Invoke-TerraformDestroy`, `Sync-TerraformCatalog`. Apply enforces 8 consistency checks in firing order: schema match (`dt-pilot.tfplan/v1`), exitCode is present/integer/zero, environment match, workspace-content hash (`*.tf` + `*.tfvars` + `.terraform.lock.hcl`), freshness (default 30 min), workingDir match (OS-aware path compare; missing field is a hard failure), planBinary shape (present, string, no `..` traversal, rooted only if under workdir), and binary plan still on disk. Each gate produces a targeted error so malformed envelopes are diagnosed distinctly from failed-plan / drift cases.
  - `config/catalog/terraform.json` (+ `terraform.schema.json`) — reflected catalog of 6 `dynatrace_*` resource types (`dynatrace_management_zone_v2`, `dynatrace_autotag_v2`, `dynatrace_alerting`, `dynatrace_slo_v2`, `dynatrace_notification`, `dynatrace_dashboard`). Registered as the second backend in `config/catalog/backends.json`.
  - `modules/terraform/configs/<family>/<resource>/` — generated scaffolds (3 files per entry: `SCAFFOLD.md`, `main.tf.example`, `variables.tf.example`), byte-deterministic across PS editions, gated by `Sync-TerraformCatalog.ps1 -Check` in the pre-commit gate.
  - `examples/terraform-baseline/` — working stack mirroring `examples/baseline-stack/`: management zone, alerting profile, SLO, email notification; per-env `.tfvars` + per-developer `.local.tfvars` (gitignored).
  - `.vscode/mcp.json` + catalog — disabled `terraform` MCP server entry (HashiCorp's `terraform-mcp-server` via Docker); toggle on via `Set-McpServerState.ps1 -Server terraform -Enable` when actively authoring `.tf`.
  - `scripts/Test-McpConfigSecrets.ps1` extended to scan committed `.tf`, `.tfvars`, and `.tfvars.json` files for token literals, live tenant URLs (`*.live.dynatrace.com` / `*.apps.dynatrace.com` / `*.dynatracelabs.com`), bearer-in-URL, and inline credential arguments (`api_token` / `client_id` / `client_secret` / `account_id` set to a string literal rather than a `var.` / `local.` / `data.` / `module.` reference). `url` is intentionally NOT on the inline-arg list — it's a common, legitimate argument name in non-provider blocks (webhook endpoints, HTTP data sources, dashboard tiles) and the live-tenant-URL regex already catches the leak case we care about regardless of which LHS the URL sits on. `.tfvars.json` files are JSON-parsed for the same credential field names since the HCL `=` regex doesn't match JSON syntax. The gitignored per-developer `envs/*.local.tfvars[.json]` convention is excluded from the full-repo walk.
  - `docs/TERRAFORM-DYNATRACE-INTEGRATION.md` — when to pick Terraform vs Monaco, coexistence patterns, remote-state guidance, recommended CI workflow shape, migration playbook.
  - `docs/AUTHENTICATION.md` — extended with the canonical -> Terraform-provider env-var mapping table.
  - `.gitignore` — `.terraform/`, `terraform.tfstate*`, `*.tfplan`, `envs/*.local.tfvars`.

- Scheduled catalog refresh ([Design 002](docs/design/SCHEDULED-CATALOG-REFRESH.md)):
  - `config/catalog/schemas.txt` is the curated inputs list of Dynatrace settings 2.0 schema IDs that dt-pilot reflects. Adding a row is the cheapest way to extend catalog coverage.
  - `scripts/monaco/Sync-CatalogFromSchemas.ps1` reads `schemas.txt`, calls `monaco generate schema` per ID, refreshes `summary` + new informational `liveFields`, and preserves the curated `family` + `commonParameters`. Byte-deterministic output across PS 5.1 / 7. Supports `-WhatIf` for safe local inspection and `-FetchSchemaScript` for test stubbing.
  - `.github/workflows/catalog-refresh.yml` is the weekly cron (Mondays 06:17 UTC) and `workflow_dispatch` entry-point. Runs in a gated `catalog-refresh` GitHub Actions environment that carries `DT_ENVIRONMENT` + `DT_PLATFORM_TOKEN` (read-only `settings:schemas:read` scope is sufficient). If diff exists, opens an auto-PR with `@copilot` review requested. NEVER auto-merges. Exits cleanly when the gated environment is unconfigured so the initial workflow_dispatch is a safe smoke test.
  - `config/catalog/schema.json` extended with an optional `liveFields` array (informational; refreshed by the cron, not consumed by `Sync-ConfigCatalog.ps1`).

- Multi-backend skeleton ([Design 001](docs/design/MULTI-BACKEND-SKELETON.md)):
  - `skills/iac/SKILL.md` defines the tool-agnostic harness contract (plan-as-artifact, apply gates, destroy gates, secret hygiene, MCP-first reads, branch + PR discipline).
  - `config/catalog/backends.json` (+ `backends.schema.json`) is the authoritative registry of supported backends. Tooling iterates this rather than hard-coding Monaco paths.
  - `CLAUDE.md` has a Backend Routing section that maps workspace shape to backend.
  - `Pre-Commit.ps1` iterates `backends.json` for per-backend manifest checks and catalog sync checks; new backends are picked up automatically.

### Changed
- **Scripts reorganized into `scripts/monaco/`.** Every Monaco-specific wrapper (`Invoke-Monaco*.ps1`, `Validate-Monaco.ps1`, `Test-MonacoManifest.ps1`, `Initialize-MonacoWorkspace.ps1`, `Get-MonacoVersion.ps1`, `Sync-ConfigCatalog.ps1`, `_Common.ps1`) now lives under `scripts/monaco/`. Repo-wide scripts (`Pre-Commit.ps1`, `Test-McpConfigSecrets.ps1`, MCP launchers) stay at `scripts/` root.

### Removed
- Compatibility shims at the legacy `scripts/Invoke-Monaco*.ps1`, `scripts/Validate-Monaco.ps1`, `scripts/Test-MonacoManifest.ps1`, `scripts/Initialize-MonacoWorkspace.ps1`, `scripts/Get-MonacoVersion.ps1`, and `scripts/Sync-ConfigCatalog.ps1` paths. Use the canonical paths under `scripts/monaco/` instead. Closes [#11](https://github.com/TemplateMechanics/dt-pilot/issues/11).
