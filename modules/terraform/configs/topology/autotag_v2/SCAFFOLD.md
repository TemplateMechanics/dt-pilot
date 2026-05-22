<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Auto-Tag Rule (v2)

**Terraform resource type:** `dynatrace_autotag_v2`
**Family:** topology

## Summary

Settings 2.0 auto-tag rule. Tags become the primary input to downstream management-zone and alerting filters, so auto-tags usually deploy before everything else that references them.

## How to adopt

1. Copy the two `*.example` files into your project at any path Terraform discovers (typically the project root or a sibling `modules/` directory), and rename:
   - `main.tf.example` -> `main.tf` (or merge into an existing main.tf)
   - `variables.tf.example` -> `variables.tf` (or merge into an existing variables.tf)
2. Fill in the `TODO` markers with real values; replace placeholder argument shapes with the real provider schema from:
   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/autotag_v2](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/autotag_v2)
3. `./scripts/terraform/Validate-Terraform.ps1 -Path .` then `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan`.

## Pre-declared variables

- `tag_name` (`string`) -- Tag key (the right-hand side will come from the rule expression).
- `rule_expression` (`string`) -- DQL-like or attribute predicate that selects the entities to tag. Feeds a nested rules { } block -- no top-level provider argument.
