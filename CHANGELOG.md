# Changelog

All notable changes to dt-pilot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository meta surface: `README`, `LICENSE` (MIT), tuned `.gitignore`, `CONTRIBUTING`, `SECURITY`, `CODE_OF_CONDUCT`, GitHub PR template, and `docs/BRANCH-WORKFLOW.md` codifying the never-commit-to-main + squash-only merge policy.
- Multi-backend skeleton ([Design 001](docs/design/MULTI-BACKEND-SKELETON.md)):
  - `skills/iac/SKILL.md` defines the tool-agnostic harness contract (plan-as-artifact, apply gates, destroy gates, secret hygiene, MCP-first reads, branch + PR discipline).
  - `config/catalog/backends.json` (+ `backends.schema.json`) is the authoritative registry of supported backends. Tooling iterates this rather than hard-coding Monaco paths.
  - `CLAUDE.md` has a Backend Routing section that maps workspace shape to backend.
  - `Pre-Commit.ps1` iterates `backends.json` for per-backend manifest checks and catalog sync checks; new backends are picked up automatically.

### Changed
- **Scripts reorganized into `scripts/monaco/`.** Every Monaco-specific wrapper (`Invoke-Monaco*.ps1`, `Validate-Monaco.ps1`, `Test-MonacoManifest.ps1`, `Initialize-MonacoWorkspace.ps1`, `Get-MonacoVersion.ps1`, `Sync-ConfigCatalog.ps1`, `_Common.ps1`) now lives under `scripts/monaco/`. Repo-wide scripts (`Pre-Commit.ps1`, `Test-McpConfigSecrets.ps1`, MCP launchers) stay at `scripts/` root.

### Deprecated
- Compatibility shims at the legacy `scripts/Invoke-Monaco*.ps1`, `scripts/Validate-Monaco.ps1`, etc. paths. They forward to `scripts/monaco/*` and emit a deprecation warning to stderr on every invocation. **Scheduled for removal in the release after the one that introduces them** — update invocations now. Tracking issue to be filed after this PR merges.
