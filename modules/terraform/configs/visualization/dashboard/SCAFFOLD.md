<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Dashboard

**Terraform resource type:** `dynatrace_dashboard`
**Family:** visualization

## Summary

Dynatrace dashboard payload. Templates tend to be large -- prefer storing the bulk as a JSON file referenced via file() rather than inlining megabytes of HCL.

## How to adopt

1. Copy the two `*.example` files into your project at any path Terraform discovers (typically the project root or a sibling `modules/` directory), and rename:
   - `main.tf.example` -> `main.tf` (or merge into an existing main.tf)
   - `variables.tf.example` -> `variables.tf` (or merge into an existing variables.tf)
2. Fill in the `TODO` markers with real values; replace placeholder argument shapes with the real provider schema from:
   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/dashboard](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/dashboard)
3. `./scripts/terraform/Validate-Terraform.ps1 -Path .` then `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan`.

## Pre-declared variables

- `dashboard_name` (`string`) -- Display name shown in the Dynatrace UI. Lives in the nested dashboard_metadata { name = ... } block -- no top-level provider argument.
- `owner` (`string`) -- Owner email or service-account identifier. Lives in the nested dashboard_metadata { owner = ... } block -- no top-level provider argument.
