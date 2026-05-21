# Example — terraform-baseline

A Terraform-flavored mirror of [`examples/baseline-stack/`](../baseline-stack/) (the Monaco example). Four `dynatrace_*` resources wired together via direct attribute references:

```
dynatrace_management_zone_v2.baseline
        |
        +---- dynatrace_alerting.baseline
        |              |
        |              +---- dynatrace_notification.baseline_email
        |
        +---- dynatrace_slo_v2.baseline_availability
```

Copy this folder as the starting point for a new Terraform-managed Dynatrace estate. The structure deliberately matches the Monaco example so you can diff approach against approach.

## Layout

| Path | Purpose |
|---|---|
| `versions.tf` | Pinned Terraform and `dynatrace-oss/dynatrace` provider versions. |
| `providers.tf` | Empty `provider "dynatrace" {}` block. Every credential comes from env vars at runtime. |
| `variables.tf` | Typed + documented variables with `validation` blocks on numeric ranges. |
| `main.tf` | Four resources + two outputs. |
| `envs/dev.tfvars`, `envs/prod.tfvars` | Per-environment shareable values; committed. |
| `envs/<env>.local.tfvars` | Per-developer overrides; **gitignored**. |

## Required environment variables

The wrappers translate canonical dt-pilot env vars to the provider-specific names — you set the canonical names once:

| Canonical (you set) | Provider sees | Notes |
|---|---|---|
| `DT_ENVIRONMENT` | `DT_ENV_URL` | Your Dynatrace platform URL |
| `DT_PLATFORM_TOKEN` | `DT_API_TOKEN` | Platform token (preferred for dev) |
| `OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET` | `DT_CLIENT_ID` + `DT_CLIENT_SECRET` | OAuth (preferred for CI / prod) |

See [`docs/AUTHENTICATION.md`](../../docs/AUTHENTICATION.md) for the auth-mode walkthrough and token provisioning steps.

## How to run

> The dt-pilot wrappers refuse to apply without a saved plan envelope from `Invoke-TerraformPlan.ps1`. The sequence below is non-negotiable; see [`skills/iac/SKILL.md`](../../skills/iac/SKILL.md) and [`agents/terraform.agent.md`](../../agents/terraform.agent.md).

```powershell
# First-time clone or after editing versions.tf:
./scripts/terraform/Initialize-TerraformWorkspace.ps1 -Path examples/terraform-baseline

# Fast feedback (fmt + validate; no creds needed):
./scripts/terraform/Validate-Terraform.ps1 -Path examples/terraform-baseline

# Plan against dev (needs DT_ENVIRONMENT + creds):
./scripts/terraform/Invoke-TerraformPlan.ps1 `
    -Path examples/terraform-baseline `
    -Environment dev `
    -VarFile envs/dev.tfvars `
    -Out tfplan

# Review dryrun/dev.json with the user; then after explicit approval:
./scripts/terraform/Invoke-TerraformApply.ps1 `
    -Path examples/terraform-baseline `
    -Environment dev `
    -PlanFile dryrun/dev.json
```

## Promoting through environments

Terraform itself has no "promote" concept. Promotion is rerunning the same plan/apply cycle against the next environment's `.tfvars`:

1. Land a change in `dev`: PR + Copilot review + squash-merge + manual `dev` plan/apply.
2. Re-plan against `staging` (when present); human review.
3. Re-plan against `prod`; human review.
4. Apply prod.

Each promotion step is an explicit invocation with the next `-Environment` + `-VarFile`. Production deploys should be gated by a CI environment requiring reviewer approval before the workflow can read the prod secrets — see [`agents/chief-systems-engineer.agent.md`](../../agents/chief-systems-engineer.agent.md).

## What this example deliberately does NOT do

- **No remote state backend.** Local state is fine for this demo; real projects use S3+DynamoDB / Azure Blob / HCP Terraform. See [`docs/TERRAFORM-DYNATRACE-INTEGRATION.md`](../../docs/TERRAFORM-DYNATRACE-INTEGRATION.md) for remote-state guidance.
- **No account-management resources.** Groups / policies / user assignments are a separate concern with different review cadence; keep them in a separate Terraform project.
- **No legacy (non-`_v2`) resources.** Settings 2.0 is the long-term direction.

## Modifying this example

If you fork this stack into your own project:

1. **Rename the resource local names** (`baseline`, `baseline_availability`, `baseline_email`) to fit your team's convention.
2. **Update the variable defaults** in `variables.tf` or override them in `envs/<env>.tfvars`.
3. **Re-validate** with `./scripts/terraform/Validate-Terraform.ps1 -Path .` before planning.
4. **Run plan against each environment**; expect the first plan after a refactor to show only the rename (via implicit destroy/recreate UNLESS you add a `moved {}` block — see [`skills/terraform/SKILL.md`](../../skills/terraform/SKILL.md) §7).
