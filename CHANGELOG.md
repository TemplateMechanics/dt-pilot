# Changelog

All notable changes to dt-pilot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository meta surface: `README`, `LICENSE` (MIT), tuned `.gitignore`, `CONTRIBUTING`, `SECURITY`, `CODE_OF_CONDUCT`, GitHub PR template, and `docs/BRANCH-WORKFLOW.md` codifying the never-commit-to-main + squash-only merge policy.
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

### Deprecated
- Compatibility shims at the legacy `scripts/Invoke-Monaco*.ps1`, `scripts/Validate-Monaco.ps1`, etc. paths. They forward to `scripts/monaco/*` and emit a deprecation warning to stderr on every invocation. **Scheduled for removal in the release after the one that introduces them** — update invocations now. Tracking issue to be filed after this PR merges.
