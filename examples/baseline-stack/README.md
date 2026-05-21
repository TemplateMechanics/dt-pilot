# Example — baseline-stack

A minimal but complete Monaco project showing the four most common Dynatrace settings 2.0 schemas wired together via reference parameters. Copy this folder as the starting point for a new dt-pilot-managed Dynatrace estate.

## What it deploys

```
management zone (baseline-services)
        |
        +---- alerting profile (baseline-alerting)
        |              |
        |              +---- email notification (baseline-email-notification)
        |
        +---- SLO (baseline-availability-slo)
```

Four configs, three references. Every reference uses Monaco's `[ schema, id, property ]` shorthand and produces an implicit deploy order: the management zone deploys first, then the alerting profile and SLO (independent of each other), then the notification.

## Layout

| Path | Purpose |
|---|---|
| `manifest.yaml` | Top-level deployment manifest. Three environments (`dev` / `staging` / `prod`) across two groups (`non-prod` / `prod`). Every URL and credential is an env-var reference. |
| `baseline/management-zones/` | The management zone (`builtin:management-zones`). |
| `baseline/alerting-profile/` | The alerting profile (`builtin:alerting.profile`) referencing the management zone. |
| `baseline/slo/` | An availability SLO (`builtin:slo`) referencing the management zone. |
| `baseline/notifications/` | An email problem notification (`builtin:problem.notifications`) referencing the alerting profile. |

## Required environment variables

| Variable | Used by | Notes |
|---|---|---|
| `DT_ENVIRONMENT_DEV` | manifest (`dev` env URL) | Your Dynatrace dev tenant URL |
| `DT_PLATFORM_TOKEN_DEV` | manifest (`dev` env auth) | Platform token scoped to `settings:objects:read settings:objects:write settings:schemas:read app-engine:apps:run` |
| `DT_ENVIRONMENT_STAGING` | manifest (`staging` env URL) | Staging tenant URL |
| `OAUTH_CLIENT_ID_STAGING` / `OAUTH_CLIENT_SECRET_STAGING` | manifest (`staging` env auth) | OAuth client with the same scopes as above |
| `DT_ENVIRONMENT_PROD` | manifest (`prod` env URL) | Production tenant URL |
| `OAUTH_CLIENT_ID_PROD` / `OAUTH_CLIENT_SECRET_PROD` | manifest (`prod` env auth) | Production OAuth client |
| `DT_PILOT_NOTIFY_EMAIL` *(optional)* | `baseline-email-notification` recipient | Defaults to `ops@example.com` if unset. Override for real on-call routing. |

See [`docs/AUTHENTICATION.md`](../../docs/AUTHENTICATION.md) for the auth-mode walkthrough and token provisioning steps.

## How to run

> The dt-pilot wrappers refuse to deploy without a saved dry-run from `Invoke-MonacoDryRun.ps1`. The sequence below is non-negotiable; see [`CLAUDE.md`](../../CLAUDE.md) Key Rules 6–8.

```powershell
# Sanity check (validates Monaco, manifest, project directories):
./scripts/Initialize-MonacoWorkspace.ps1 -Path examples/baseline-stack

# Schema-only check (dependency-free; runs in pre-commit + CI):
./scripts/Test-MonacoManifest.ps1 -Path examples/baseline-stack

# Full validate (calls 'monaco deploy --dry-run'; needs Monaco installed):
./scripts/Validate-Monaco.ps1 -Path examples/baseline-stack -Environment dev

# Produce a reviewable dry-run artifact:
./scripts/Invoke-MonacoDryRun.ps1 -Path examples/baseline-stack -Environment dev -Out dryrun/dev.json

# After human approval:
./scripts/Invoke-MonacoDeploy.ps1 -Path examples/baseline-stack -Environment dev -DryRunFile dryrun/dev.json
```

## Promoting through environments

The harness intentionally has no "promote" command — promotion is just running the same dry-run/deploy cycle against the next environment. Typical flow:

1. Land a change in `dev` (PR + Copilot review + squash-merge + manual deploy with `-Environment dev`).
2. Re-run dry-run against `staging`; have a human review the diff.
3. Deploy to `staging`.
4. Re-run dry-run against `prod`; have a human review the diff; deploy.

Each promotion step is an explicit invocation of the deploy wrapper with the next `-Environment`. Production deploys should be guarded by a CI environment requiring reviewer approval before the workflow can read the prod secrets — see [`agents/chief-systems-engineer.agent.md`](../../agents/chief-systems-engineer.agent.md) for the multi-environment strategy.

## What this example deliberately does NOT do

- **No account-management.** Account configs (groups, policies, user assignments) belong in a separate project under `account-projects/` so they can have their own reviewer set and deploy cadence.
- **No classic-API configs.** Settings 2.0 covers everything here; classic-API configs only appear when settings 2.0 doesn't yet have an equivalent.
- **No host-scoped settings.** The management zone is `scope: environment`. Host-scoped settings need a specific `HOST_GROUP-<id>` and would need a download or MCP lookup to discover the right ID — out of scope for an introductory example.

## Modifying this example

If you fork this stack into your own project:

1. **Rename every `id:`** — the `id` is identity. Reusing `baseline-services` in two repos pointed at the same tenant will conflict.
2. **Rename the project folder** (`baseline/` → `<your-team>/`) and the matching `projects[].name` in `manifest.yaml`.
3. **Update `zoneName`, `profileName`, `sloName`, and `notificationName` parameter values** so the resulting Dynatrace objects have your team's prefix.
4. **Re-validate** with `Test-MonacoManifest.ps1` and `Validate-Monaco.ps1` before dry-running.
