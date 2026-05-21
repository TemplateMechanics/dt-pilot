<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Auto-Tag Rule

**Schema ID:** `builtin:tags.auto-tagging`
**Family:** topology
**Default scope:** environment

## Summary

Rule for attaching tags to entities based on attribute / metadata predicates. Tags are the primary way to compose downstream management-zone and alerting filters.

## How to adopt

1. Copy the two `*.example` files in this directory into your own project at `projects/<your-project>/builtin-tags.auto-tagging/` and rename:
   - `config.yaml.example` -> `config.yaml`
   - `template.json.example` -> `template.json` (or rename to match what the new `config.yaml` references)
2. Fill in the `TODO` markers in `config.yaml` with real parameter values.
3. Replace the placeholder `template.json` body with the real Dynatrace payload. Get the live schema first via:

   ```powershell
   ./scripts/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema builtin:tags.auto-tagging
   ```

4. Register the project in the manifest's `projects:` list, then validate and dry-run before deploying.

## Pre-declared parameters

- `tagName`
- `ruleExpression`
