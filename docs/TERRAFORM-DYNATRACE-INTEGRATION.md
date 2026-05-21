# Terraform + Dynatrace integration guide

This document covers how to pick between Monaco and Terraform for managing Dynatrace configuration, how to run them side by side on the same tenant, and the operational patterns dt-pilot opinionates on for the Terraform path.

For provider-specific syntax and resource shapes, read [`skills/terraform/SKILL.md`](../skills/terraform/SKILL.md) first. For the tool-agnostic harness contract, read [`skills/iac/SKILL.md`](../skills/iac/SKILL.md).

---

## When to pick which

| Situation | Pick |
|---|---|
| Greenfield Dynatrace estate; team has no existing IaC | **Monaco** — purpose-built, smaller surface, easier to grok end-to-end |
| Team already runs Terraform for cloud infra and wants one tool | **Terraform** — fewer technologies to operate |
| Mix of settings 2.0 + legacy classic-API configs Monaco doesn't fully cover | **Terraform** — the `dynatrace-oss/dynatrace` provider covers both surfaces |
| Account management (groups, policies, user assignments) | **Either** — pick by team review/ownership topology |
| Multi-environment fan-out with the same shape | **Either** — Terraform uses workspaces or per-env state files; Monaco uses `environmentGroups` |
| Need to declare Dynatrace alongside cloud infra that Terraform already manages (e.g. an alerting profile that references an EC2 host group provisioned by AWS resources in the same PR) | **Terraform** — single plan, single apply |

When the team is split (some squads on Terraform, some on Monaco), it's legitimate to use both on the same tenant — see Coexistence below.

---

## Coexistence on a single tenant

Both backends can manage Dynatrace configuration on the same tenant. The only hard rule:

> **Each Dynatrace object is owned by exactly one tool.**

Drift between Terraform state and Monaco's settings 2.0 reality WILL silently overwrite changes from whichever runs last. Partition cleanly:

- **By object type.** Easiest. e.g. management zones via Terraform, dashboards via Monaco. Per-type ownership is easy to enforce by lint.
- **By team.** Each owning team picks its tool for the configs it owns. Naming-prefix conventions (`team-a-*`) help reviewers spot cross-team ownership violations during plan review.
- **NEVER by environment.** Don't run Monaco against dev and Terraform against prod for the same logical config — promotion becomes a tool migration.

When you adopt both:

1. Inventory every existing Dynatrace object (`monaco download` or `terraform import {}` blocks against the live tenant). Don't trust UI lists; use MCP `find_entity_by_name` and `execute_dql` to enumerate.
2. Decide ownership per object before touching either tool.
3. Add the matching wrapper invocations to each team's CI; let dt-pilot's pre-commit gates enforce per-tool hygiene.

---

## State management for the Terraform backend

dt-pilot's Terraform backend is opinionated about state:

- **Local state is fine for `examples/terraform-baseline/`** — it's a demo, not a production estate.
- **Real projects use remote state.** Pick one:
  - **AWS:** S3 (versioned, encrypted) + DynamoDB locking.
  - **Azure:** Azure Blob (versioned, encrypted) + container locking.
  - **GCP:** GCS (versioned, encrypted) — locking via state-locking serverless project.
  - **HCP Terraform / Terraform Cloud:** HashiCorp-hosted state + native locking.
- **Never commit `terraform.tfstate`.** `.gitignore` covers it; double-check before staging.
- **The state file contains secrets** (everything `sensitive = true` is still in plaintext in state). Encrypt at rest, restrict IAM access to the deploy role only.

`Invoke-TerraformPlan.ps1`'s `workspaceHash` does NOT include the state file. State is server-side / per-deploy, not source; including it would invalidate every plan as soon as state evolves. The hash gates `terraform apply` against SOURCE drift only; STATE drift between plan and apply is Terraform's own refresh problem, and `terraform apply <planfile>` doesn't refresh.

### Recommended remote-state shape

A typical `backend.tf` for a dt-pilot Terraform project on AWS:

```hcl
terraform {
  backend "s3" {
    bucket         = "myorg-dynatrace-tf-state"
    key            = "estates/main/terraform.tfstate"  # one key per logical estate
    region         = "us-east-1"
    dynamodb_table = "myorg-dynatrace-tf-locks"
    encrypt        = true
    # Backend args don't take string interpolation -- supply them via
    # -backend-config=<file> at terraform init time if values differ
    # per environment.
  }
}
```

dt-pilot's `Initialize-TerraformWorkspace.ps1` doesn't hard-code a backend; the consuming project owns `backend.tf` and any `-backend-config=<file>` arguments.

---

## CI / production deploy topology

The cron + auto-PR shape that landed for the Monaco catalog refresh ([Design 002](design/SCHEDULED-CATALOG-REFRESH.md)) is overkill for routine Terraform deploys — Terraform plans don't drift weekly, they drift on every `*.tf` commit. The recommended shape for Terraform-backed Dynatrace projects in CI:

| Workflow | Trigger | What |
|---|---|---|
| `tf-validate` | every PR | `Validate-Terraform.ps1` (fmt + validate); no creds |
| `tf-plan` | every PR (after validate) | `Invoke-TerraformPlan.ps1 -Environment dev`; posts the envelope summary as a PR comment for human review |
| `tf-apply-dev` | merge to main | `Invoke-TerraformApply.ps1 -Environment dev -PlanFile <fresh-plan>` against a gated `dynatrace-dev` environment |
| `tf-apply-prod` | manual `workflow_dispatch` | same against `dynatrace-prod` with reviewer-required gating |

The `Invoke-TerraformApply` workspace-hash check means CI MUST re-plan after merging; using the PR's plan post-merge would mismatch the hash because the squash-merge produces different commit content than the branch the plan was produced from.

---

## Migrating from Monaco to Terraform (or vice versa)

Five steps for either direction:

1. **Inventory** the objects you want to migrate (Dynatrace MCP `find_entity_by_name` / `execute_dql`).
2. **Author** the new tool's representation (`*.tf` for Terraform, `manifest.yaml` + `config.yaml` + `template.json` for Monaco). Don't deploy yet.
3. **Import** existing objects into the new tool's state:
   - Terraform: `import {}` blocks (1.5+) per object, committed to source.
   - Monaco: `monaco download` followed by reorganizing the downloaded files into proper projects.
4. **Plan / dry-run** the new tool against the existing tenant. Expect a no-op plan; non-zero means the import wasn't lossless and you need to reconcile.
5. **Cut over.** Remove the old tool's ownership (Monaco: remove the project from `manifest.yaml` and `monaco delete` the configs from the manifest's state; Terraform: `removed {}` blocks (1.7+) to drop from state without destroying).

Plan the cutover in a single PR per logical group; piecemeal migrations leak ownership.

---

## Why dt-pilot doesn't vendor tf-pilot

[tf-pilot](https://github.com/TemplateMechanics/tf-pilot) is dt-pilot's upstream-inspiration for the Terraform wrapper shapes (plan-as-artifact, apply-requires-plan, etc.). It's the right harness for **multi-cloud / multi-provider Terraform** — its provider catalog spans AWS, Azure, GCP, Kubernetes, Helm, GitHub, Azure DevOps, GitLab, AND Dynatrace, plus an OPA policy gate and a YAML-driven composition layer.

dt-pilot is **Dynatrace-vertical** — it ships Dynatrace-MCP-first reads, Dynatrace-specific agent personas, and a curated catalog of `dynatrace_*` resources. For a team running both cloud infra (via Terraform) and Dynatrace (also via Terraform), the right move is to use tf-pilot for the cloud projects and dt-pilot for the Dynatrace project; they coexist in separate repositories and share the same conventions.

---

## Further reading

- [`skills/iac/SKILL.md`](../skills/iac/SKILL.md) — the tool-agnostic harness contract
- [`skills/terraform/SKILL.md`](../skills/terraform/SKILL.md) — Terraform-via-Dynatrace-provider specifics
- [`agents/terraform.agent.md`](../agents/terraform.agent.md) — agent persona for routine work
- [`agents/chief-systems-engineer.agent.md`](../agents/chief-systems-engineer.agent.md) — cross-cutting architecture
- [`docs/AUTHENTICATION.md`](AUTHENTICATION.md) — env-var mapping (canonical → provider names) lives there
- [Dynatrace provider docs](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs)
- [tf-pilot](https://github.com/TemplateMechanics/tf-pilot) — multi-cloud / multi-provider Terraform harness
