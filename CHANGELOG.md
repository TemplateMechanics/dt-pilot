# Changelog

All notable changes to dt-pilot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository meta surface: `README`, `LICENSE` (MIT), tuned `.gitignore`, `CONTRIBUTING`, `SECURITY`, `CODE_OF_CONDUCT`, GitHub PR template, and `docs/BRANCH-WORKFLOW.md` codifying the never-commit-to-main + squash-only merge policy.
- Terraform backend ([Design 003](docs/design/TERRAFORM-BACKEND.md)). Adds the second backend behind the multi-backend skeleton from Design 001. Cherry-picks wrapper shapes from [tf-pilot](https://github.com/TemplateMechanics/tf-pilot) and adapts them to dt-pilot's `dt-pilot.tfplan/v1` envelope.
  - `skills/terraform/SKILL.md` + `agents/terraform.agent.md` — defers to `skills/iac/SKILL.md` for the cross-cutting contract; covers `dynatrace-oss/dynatrace` provider specifics.
  - `scripts/terraform/` — `_Common.ps1` (executable resolution, canonical->provider env-var translation, workspace hash, plan-envelope read/write) plus 7 wrappers: `Get-TerraformVersion`, `Initialize-TerraformWorkspace`, `Validate-Terraform`, `Invoke-TerraformPlan`, `Invoke-TerraformApply`, `Invoke-TerraformDestroy`, `Sync-TerraformCatalog`. Apply enforces 5 checks: schema match, environment match, workspace-content hash, freshness (default 30 min), binary plan still on disk.
  - `config/catalog/terraform.json` (+ `terraform.schema.json`) — reflected catalog of 6 `dynatrace_*` resource types (`dynatrace_management_zone_v2`, `dynatrace_autotag_v2`, `dynatrace_alerting`, `dynatrace_slo_v2`, `dynatrace_notification`, `dynatrace_dashboard`). Registered as the second backend in `config/catalog/backends.json`.
  - `modules/terraform/configs/<family>/<resource>/` — generated scaffolds (3 files per entry: `SCAFFOLD.md`, `main.tf.example`, `variables.tf.example`), byte-deterministic across PS editions, gated by `Sync-TerraformCatalog.ps1 -Check` in the pre-commit gate.
  - `examples/terraform-baseline/` — working stack mirroring `examples/baseline-stack/`: management zone, alerting profile, SLO, email notification; per-env `.tfvars` + per-developer `.local.tfvars` (gitignored).
  - `.vscode/mcp.json` + catalog — disabled `terraform` MCP server entry (HashiCorp's `terraform-mcp-server` via Docker); toggle on via `Set-McpServerState.ps1 -Server terraform -Enable` when actively authoring `.tf`.
  - `scripts/Test-McpConfigSecrets.ps1` extended to scan committed `.tf` files for token literals, live tenant URLs, bearer-in-URL, and inline provider arguments (`url`/`api_token`/`client_id`/`client_secret`/`account_id` set to a string literal rather than a `var.`/`local.`/`data.` reference).
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
