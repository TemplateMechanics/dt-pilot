<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/monaco/Sync-ConfigCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Management Zone

**Schema ID:** `builtin:management-zones`
**Family:** topology
**Default scope:** environment

## Summary

Service / host / process-group filter used for access control and as a referenceable target by alerting profiles, SLOs, dashboards, and notification configs.

## How to adopt

1. Copy the two `*.example` files in this directory into your own project at `projects/<your-project>/builtin-management-zones/` and rename:
   - `config.yaml.example` -> `config.yaml`
   - `template.json.example` -> `template.json` (or rename to match what the new `config.yaml` references)
2. Fill in the `TODO` markers in `config.yaml` with real parameter values.
3. Replace the placeholder `template.json` body with the real Dynatrace payload. Get the live schema first via:

   ```powershell
   ./scripts/monaco/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema builtin:management-zones
   ```

4. Register the project in the manifest's `projects:` list, then validate and dry-run before deploying.

## Pre-declared parameters

- `zoneName`
