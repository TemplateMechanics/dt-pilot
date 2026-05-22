<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->
<!-- SPDX-License-Identifier: MIT -->
# Scaffold: Problem Notification

**Terraform resource type:** `dynatrace_notification`
**Family:** alerting

## Summary

Routes problems matching an alerting profile to email / Slack / webhook / PagerDuty / Jira / OpsGenie / xMatters. The per-channel payload lives in nested blocks (email {} / slack {} / etc.); generate the schema or read the provider docs before authoring.

## How to adopt

1. Copy the two `*.example` files into your project at any path Terraform discovers (typically the project root or a sibling `modules/` directory), and rename:
   - `main.tf.example` -> `main.tf` (or merge into an existing main.tf)
   - `variables.tf.example` -> `variables.tf` (or merge into an existing variables.tf)
2. Fill in the `TODO` markers with real values; replace placeholder argument shapes with the real provider schema from:
   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/notification](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/notification)
3. `./scripts/terraform/Validate-Terraform.ps1 -Path .` then `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan`.

## Pre-declared variables

- `notification_name` (`string`) -- Display name for the notification.
- `alerting_profile_id` (`string`) -- ID of the alerting profile this notification fires against.
- `recipient_email` (`string`) -- Email recipient. Feeds the nested email { to = [...] } block -- no top-level provider argument.
