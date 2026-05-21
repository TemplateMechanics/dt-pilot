<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Problem Notification â€” Email

**Schema ID:** `builtin:problem.notifications/email`
**Family:** alerting
**Default scope:** environment

## Summary

Per-type scaffold for builtin:problem.notifications when the channel is EMAIL. Other channels (SLACK, WEBHOOK, PAGERDUTY, JIRA, OPSGENIE, XMATTERS) each have their own required fields; consult monaco generate schema before authoring.

## How to adopt

1. Copy the two `*.example` files in this directory into your own project at `projects/<your-project>/builtin-problem.notifications-email/` and rename:
   - `config.yaml.example` -> `config.yaml`
   - `template.json.example` -> `template.json` (or rename to match what the new `config.yaml` references)
2. Fill in the `TODO` markers in `config.yaml` with real parameter values.
3. Replace the placeholder `template.json` body with the real Dynatrace payload. Get the live schema first via:

   ```powershell
   ./scripts/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema builtin:problem.notifications/email
   ```

4. Register the project in the manifest's `projects:` list, then validate and dry-run before deploying.

## Pre-declared parameters

- `notificationName`
- `alertingProfileId`
- `recipientEmail`
