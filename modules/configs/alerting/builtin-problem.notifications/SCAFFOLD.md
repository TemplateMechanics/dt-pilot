<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Problem Notification

**Schema ID:** `builtin:problem.notifications`
**Family:** alerting
**Default scope:** environment

## Summary

Email / Slack / webhook / PagerDuty / Jira / OpsGenie / xMatters routing for problems matching an alerting profile. The per-type payload shape differs significantly â€” generate the schema with Invoke-MonacoGenerate before authoring.

## How to adopt

1. Copy the two `*.example` files in this directory into your own project at `projects/<your-project>/builtin-problem.notifications/` and rename:
   - `config.yaml.example` -> `config.yaml`
   - `template.json.example` -> `template.json` (or rename to match what the new `config.yaml` references)
2. Fill in the `TODO` markers in `config.yaml` with real parameter values.
3. Replace the placeholder `template.json` body with the real Dynatrace payload. Get the live schema first via:

   ```powershell
   ./scripts/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema builtin:problem.notifications
   ```

4. Register the project in the manifest's `projects:` list, then validate and dry-run before deploying.

## Pre-declared parameters

- `notificationName`
- `alertingProfileId`
