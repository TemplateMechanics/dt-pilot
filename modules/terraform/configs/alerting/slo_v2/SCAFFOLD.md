<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Service Level Objective (v2)

**Terraform resource type:** `dynatrace_slo_v2`
**Family:** alerting

## Summary

Settings 2.0 SLO. evaluation_type is AGGREGATE or EVENT_BASED with different required fields per type. The warning threshold MUST be less strict than the target (lower percentage) so warnings fire before the SLO breaches.

## How to adopt

1. Copy the two `*.example` files into your project at any path Terraform discovers (typically the project root or a sibling `modules/` directory), and rename:
   - `main.tf.example` -> `main.tf` (or merge into an existing main.tf)
   - `variables.tf.example` -> `variables.tf` (or merge into an existing variables.tf)
2. Fill in the `TODO` markers with real values; replace placeholder argument shapes with the real provider schema from:
   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/slo_v2](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/slo_v2)
3. `./scripts/terraform/Validate-Terraform.ps1 -Path .` then `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan`.

## Pre-declared variables

- `slo_name` (`string`) -- Display name for the SLO.
- `target_pct` (`number`) -- Target percentage (0-100). Validation lives in the consuming variables.tf.
- `warning_pct` (`number`) -- Warning percentage (0-100). MUST be lower than target_pct.
- `management_zone_id` (`string`) -- ID of the management zone the SLO filters on. Used in the filter expression (e.g. 'type(SERVICE),mzId(${var.management_zone_id})') -- no top-level provider argument.
