<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/monaco/Sync-ConfigCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Metric-Event Anomaly Detection

**Schema ID:** `builtin:anomaly-detection.metric-events`
**Family:** alerting
**Default scope:** environment

## Summary

Threshold / baseline anomaly rule over a metric selector; emits CUSTOM_ALERT problems when triggered.

## How to adopt

1. Copy the two `*.example` files in this directory into your own project at `projects/<your-project>/builtin-anomaly-detection.metric-events/` and rename:
   - `config.yaml.example` -> `config.yaml`
   - `template.json.example` -> `template.json` (or rename to match what the new `config.yaml` references)
2. Fill in the `TODO` markers in `config.yaml` with real parameter values.
3. Replace the placeholder `template.json` body with the real Dynatrace payload. Get the live schema first via:

   ```powershell
   ./scripts/monaco/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema builtin:anomaly-detection.metric-events
   ```

4. Register the project in the manifest's `projects:` list, then validate and dry-run before deploying.

## Pre-declared parameters

- `eventName`
- `metricSelector`
- `threshold`
