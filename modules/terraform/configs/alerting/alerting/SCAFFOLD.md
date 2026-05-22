<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Alerting Profile

**Terraform resource type:** `dynatrace_alerting`
**Family:** alerting

## Summary

Severity-rule set that gates which problems trigger notifications. Almost always scoped to a management zone via the management_zone attribute.

## How to adopt

1. Copy the two `*.example` files into your project at any path Terraform discovers (typically the project root or a sibling `modules/` directory), and rename:
   - `main.tf.example` -> `main.tf` (or merge into an existing main.tf)
   - `variables.tf.example` -> `variables.tf` (or merge into an existing variables.tf)
2. Fill in the `TODO` markers with real values; replace placeholder argument shapes with the real provider schema from:
   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/alerting](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/alerting)
3. `./scripts/terraform/Validate-Terraform.ps1 -Path .` then `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan`.

## Pre-declared variables

- `profile_name` (`string`) -- Display name for the alerting profile.
- `management_zone_id` (`string`) -- ID of the management zone this profile is scoped to (use a resource attribute reference, not a literal MZ-id).
