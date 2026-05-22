# Skill — Dynatrace via Terraform

This is the per-backend skill for managing Dynatrace configuration through the official [`dynatrace-oss/dynatrace`](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest) Terraform provider. It is one of several backends under `skills/<backend>/SKILL.md`. The cross-backend contract — plan-as-artifact, apply gates, destroy gates, secret hygiene, MCP-first reads, branch + PR discipline — lives in [`skills/iac/SKILL.md`](../iac/SKILL.md). Read that skill first if you haven't; this document assumes you know the contract and covers Terraform's implementation of it.

Read this skill before editing any `.tf`, `.tfvars`, or `.terraform.lock.hcl` in a workspace whose `config/catalog/backends.json` lists the `terraform` backend.

Wrapper scripts referenced below live at `scripts/terraform/`. They auto-translate dt-pilot's canonical auth env vars (`DT_ENVIRONMENT`, `DT_PLATFORM_TOKEN`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`) to the provider-specific names (`DT_ENV_URL`, `DT_API_TOKEN`, `DT_CLIENT_ID`, `DT_CLIENT_SECRET`, `DT_ACCOUNT_ID`) at runtime — you set the canonical names once, the wrappers handle translation.

> **Provenance.** Wrapper shapes are inspired by [TemplateMechanics/tf-pilot](https://github.com/TemplateMechanics/tf-pilot), with adjustments for dt-pilot's tighter Dynatrace focus and its `dt-pilot.tfplan/v1` artifact envelope. tf-pilot remains the right harness for multi-cloud / multi-provider Terraform; dt-pilot's Terraform backend is opinionated for Dynatrace-vertical workflows.

---

## 1. When to use Terraform vs Monaco for Dynatrace

You usually pick one per environment, but coexistence on a single tenant is legal and common during a migration.

| Situation | Pick |
|---|---|
| Greenfield Dynatrace estate; team has no existing IaC | **Monaco** (purpose-built, smaller surface, easier to grok) |
| Team already runs Terraform for cloud infra and wants one tool | **Terraform** |
| Mix of settings 2.0 + legacy classic-API configs that Monaco doesn't cover yet | **Terraform** (provider covers both) |
| Account management (groups, policies, user assignments) | **Either** works; pick whichever matches the team's review pipeline |
| Multiple environments (dev/staging/prod) with the same shape | **Either** — Terraform uses workspaces or per-env state files; Monaco uses environment groups |

When both backends manage the same tenant, partition resources cleanly: each Dynatrace object should be owned by exactly one tool. Drift between Terraform state and Monaco's settings 2.0 reality will silently overwrite changes from whichever runs last. See [`docs/TERRAFORM-DYNATRACE-INTEGRATION.md`](../../docs/TERRAFORM-DYNATRACE-INTEGRATION.md) for coexistence patterns.

---

## 2. Project layout

dt-pilot's convention for a Terraform-backed Dynatrace project:

```text
.
├── versions.tf            # required_version + required_providers (dynatrace-oss/dynatrace pinned)
├── providers.tf           # provider "dynatrace" {}  (everything from env)
├── variables.tf           # per-environment knobs
├── main.tf                # the resources themselves
├── envs/
│   ├── dev.tfvars         # committed; dev-shareable values only
│   ├── prod.tfvars        # committed; prod-shareable values only
│   ├── dev.local.tfvars   # gitignored; per-developer overrides
│   └── prod.local.tfvars  # gitignored; per-developer overrides
├── .terraform.lock.hcl    # committed; cross-platform provider hashes
└── tfplan                 # gitignored; produced by Invoke-TerraformPlan; consumed by Invoke-TerraformApply
```

Two files dt-pilot adds on top of the standard Terraform layout:

- **`envs/<env>.local.tfvars`** — gitignored per-developer overrides. Matches the `.vscode/mcp.session.json` pattern.
- **`dryrun/<env>.json`** — the dt-pilot plan-envelope JSON written by `Invoke-TerraformPlan.ps1`. Same name + location as the Monaco artifact; different schema identifier (`dt-pilot.tfplan/v1`).

---

## 3. The `dt-pilot.tfplan/v1` plan artifact

Mirrors the Monaco `dt-pilot.dryrun/v1` envelope (same fields, different `schema` value and a few Terraform-specific keys). Both the binary `tfplan` AND the envelope must travel together — losing the binary invalidates the deploy.

```json
{
  "schema": "dt-pilot.tfplan/v1",
  "createdAtUtc": "2026-05-21T17:00:00Z",
  "environment": "dev",
  "workingDir": "/abs/path/to/examples/terraform-baseline",
  "workspaceHash": "<sha256 over .tf + .tfvars + .terraform.lock.hcl>",
  "terraformVersion": "1.10.0",
  "terraformExe": "/usr/local/bin/terraform",
  "exitCode": 0,
  "summary": {
    "wouldAdd": 4,
    "wouldChange": 0,
    "wouldDestroy": 0
  },
  "planBinary": "tfplan",
  "planJsonSummary": "<truncated `terraform show -json tfplan` output>"
}
```

`Invoke-TerraformApply.ps1` enforces the four standard checks before invoking `terraform apply`:

1. **Schema match.** Artifact's `schema` is `dt-pilot.tfplan/v1`.
2. **Environment match.** Artifact's `environment` matches `-Environment`.
3. **Workspace-content hash match.** SHA-256 over every `*.tf`, `*.tfvars`, and `.terraform.lock.hcl` in the working directory matches the artifact's `workspaceHash`. Any edit invalidates the apply.
4. **Freshness.** Artifact is no older than `-MaxAgeMinutes` (default 30).

PLUS two Terraform-specific checks:

- **WorkingDir match.** The envelope's `workingDir` (recorded as the absolute path the plan was produced for) must equal the resolved `-Path`. The comparison normalizes separators and is case-insensitive on Windows. A missing or differing `workingDir` is a hard failure — the workspace-hash gate would catch most cross-workspace cases, but an explicit path check produces a clearer error and protects against the rare same-content / different-path scenario.
- **Binary plan present.** The binary plan file at `planBinary` (path is relative to the working directory) must still exist on disk. Without it, `terraform apply tfplan` has nothing to apply.

---

## 4. Authoring `.tf` files

The dt-pilot conventions tighten standard Terraform style for Dynatrace:

### 4.1 Version pinning is mandatory

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = "~> 1.78"
    }
  }
}
```

Both Terraform and the provider get an explicit version constraint. Unpinned versions are forbidden — they invalidate the `.terraform.lock.hcl` hash check that `Invoke-TerraformApply.ps1` performs.

### 4.2 Provider block reads ONLY from env

`providers.tf`:

```hcl
provider "dynatrace" {
  # Every credential comes from env vars. The wrappers translate
  # dt-pilot's canonical names (DT_ENVIRONMENT, DT_PLATFORM_TOKEN,
  # OAUTH_CLIENT_*) to the provider-specific names (DT_ENV_URL,
  # DT_API_TOKEN, DT_CLIENT_*) before invoking terraform.
  # No url / api_token / client_id arguments here -- ever.
}
```

A committed inline-literal credential is a deployment-blocker — the `Test-McpConfigSecrets.ps1` pre-commit gate enforces two complementary rules:

1. **Inline credential argument.** Any `api_token` / `client_id` / `client_secret` / `account_id` whose RHS is a string literal (not a `var.` / `local.` / `data.` / `module.` reference) is flagged. So `api_token = "dt0c01.XXXX..."` fails, `api_token = var.api_token` passes. `url` is deliberately *not* on this list — it's a common, legitimate argument name in non-provider blocks (webhook endpoints, HTTP data sources, dashboard tiles, notification configs) and flagging every inline `url = "..."` produced too many false positives.
2. **Live Dynatrace tenant URL.** Any hardcoded `*.live.dynatrace.com` / `*.apps.dynatrace.com` / `*.dynatracelabs.com` URL is flagged wherever it appears — as the RHS of a `url =` assignment, embedded in a template string, or in a comment. This is the rule that catches a committed tenant URL even though `url` itself is off the inline-arg list.

Bearer-in-URL (`https://user:token@...`) and Dynatrace token literals (`dt0XX.<...>`) are also flagged everywhere. `.tfvars.json` files are JSON-parsed for the same credential field names since the HCL `=` regex doesn't match JSON syntax.

### 4.3 Variables are typed and documented

`variables.tf`:

```hcl
variable "zone_name" {
  type        = string
  description = "Display name for the management zone."
}

variable "target_pct" {
  type        = number
  description = "SLO target (0-100). Warning threshold must be lower (less strict)."
  default     = 99.5
  validation {
    condition     = var.target_pct > 0 && var.target_pct <= 100
    error_message = "target_pct must be in (0, 100]."
  }
}
```

Every variable carries `type` AND `description`. SLO-related variables get `validation` blocks — the same target-must-be-stricter-than-warning constraint that Monaco's SLO enforces structurally.

### 4.4 Use `*_v2` resources

The provider exposes both legacy (`dynatrace_management_zone`, `dynatrace_slo`) and settings-2.0 (`dynatrace_management_zone_v2`, `dynatrace_slo_v2`) shapes for many types. **Prefer the `_v2` form** unless you're deliberately maintaining a legacy resource — settings 2.0 is the long-term direction.

### 4.5 References between resources

Use direct attribute references; never re-declare an ID in two places:

```hcl
resource "dynatrace_management_zone_v2" "baseline" {
  name = var.zone_name
  rules { /* ... */ }
}

resource "dynatrace_alerting" "baseline" {
  name              = "baseline-alerting"
  management_zone   = dynatrace_management_zone_v2.baseline.id   # NOT "MZ-1234"
  /* ... */
}
```

The reference creates an implicit dependency edge — Terraform deploys the management zone first.

---

## 5. The Terraform lifecycle through dt-pilot wrappers

All operations route through `scripts/terraform/*.ps1`. Never type `terraform` directly in an agent-driven workflow.

| Step | Wrapper | Notes |
|---|---|---|
| Initialize / pull providers | `./scripts/terraform/Initialize-TerraformWorkspace.ps1 -Path .` | Calls `terraform init`. Re-run after editing `versions.tf` or `required_providers`. |
| Format + validate | `./scripts/terraform/Validate-Terraform.ps1 -Path .` | Runs `terraform fmt -check` and `terraform validate`. Fast feedback loop. |
| Produce a reviewable plan | `./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment dev -Out tfplan` | Writes both `tfplan` (binary) and `dryrun/dev.json` (envelope). |
| Apply a reviewed plan | `./scripts/terraform/Invoke-TerraformApply.ps1 -Path . -Environment dev -PlanFile dryrun/dev.json` | `-PlanFile` is the envelope JSON written by Invoke-TerraformPlan (NOT the binary `tfplan`; the envelope records the binary's relative path). Refuses without `-PlanFile`. Verifies schema, environment, workspace hash, freshness, planBinary existence, workingDir match. |
| Destroy (irreversible) | `./scripts/terraform/Invoke-TerraformDestroy.ps1 -Path . -Environment dev -Confirm` | Refuses without explicit `-Confirm`. Echoes resources before invoking. |
| Print version | `./scripts/terraform/Get-TerraformVersion.ps1` | Repo-wide diagnostic (no `-Path`). |
| Refresh scaffolds | `./scripts/terraform/Sync-TerraformCatalog.ps1` (or `-Check` in CI) | Regenerates `modules/terraform/configs/<family>/<resource>/`. |

The plan → apply two-step is non-negotiable. The agent persona refuses to call `terraform apply` directly; the wrapper refuses to run without a fresh, matching `-PlanFile`.

---

## 6. State management

dt-pilot's Terraform backend is opinionated about state:

- **Local state is fine for `examples/terraform-baseline/`** — it's a demo, not a production estate.
- **Real projects use remote state** — S3 + DynamoDB locking on AWS, Azure Blob + container lock, or HCP Terraform. The choice is the consuming project's; dt-pilot does not ship a backend block.
- **Never commit `terraform.tfstate`** — `.gitignore` covers it; double-check before staging.
- **The state file contains secrets** — encrypt at rest, restrict access to the deploy role only.

`Invoke-TerraformPlan.ps1`'s workspace hash does NOT include the state file (state is server-side / per-deploy, not source). The hash gates `terraform apply` against source drift only; state drift between plan and apply is Terraform's own refresh problem.

---

## 7. Refactoring without destroy/recreate

Renaming a resource address in source would normally produce a destroy/recreate. Three escape hatches Terraform provides:

- **`moved {}` blocks** (Terraform 1.5+) — for renames within the same module. Commit; plan; expect "0 to add, 0 to change, 0 to destroy".
- **`import {}` blocks** (Terraform 1.5+) — for bringing an existing Dynatrace object under management.
- **`removed {}` blocks** (Terraform 1.7+) — for removing an address from state WITHOUT destroying the underlying object.

dt-pilot's wrappers don't intercept these — they're standard Terraform constructs. The wrappers DO still enforce the plan/apply gates, so even a `moved {}`-only PR goes through the same review loop.

---

## 8. Common Dynatrace resources (v2-preferred)

| Resource | Notes |
|---|---|
| `dynatrace_management_zone_v2` | Filter rules (`ME` / `DIMENSION`). Order matters within `rules`. |
| `dynatrace_alerting` | Severity rules + management-zone reference. |
| `dynatrace_slo_v2` | `evaluation_type` is `AGGREGATE` or `EVENT_BASED`; different required fields per type. Warning < target. |
| `dynatrace_notification` | Per-type payload (`EMAIL`, `SLACK`, `WEBHOOK`, etc.) under `email {}` / `slack {}` / etc. nested blocks. |
| `dynatrace_autotag_v2` | Tag rules; precursor to most downstream management-zone composition. |
| `dynatrace_dashboard` | Large JSON-ish payload; treat as data, not as code to maintain by hand. |

When in doubt, the official docs at [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs) are authoritative for argument shapes.

---

## 9. Refusal list (also enforced by `agents/terraform.agent.md`)

The agent persona will refuse to:

- Run `terraform apply` directly without a saved `-PlanFile` from `Invoke-TerraformPlan.ps1`.
- Run `terraform destroy` without an explicit `-Confirm` and an explicit destroy authorization in the conversation.
- Commit a `provider "dynatrace" {}` block with `url`, `api_token`, `client_id`, or `client_secret` arguments inline (must come from env vars only).
- Hand-edit files under `modules/terraform/configs/` (regenerate via `Sync-TerraformCatalog.ps1`).
- Push to `main` directly.
- Squash-merge a PR before its Copilot review threads are resolved.

---

## 10. When you need information not in this skill

In priority order:

1. The Dynatrace MCP server — for DQL, entities, problems, existing settings state. Same read surface as the Monaco backend; provider choice is irrelevant for reads.
2. The Terraform MCP server (`hashicorp/terraform-mcp-server`) — for provider registry / module / state context. Off by default in `.vscode/mcp.json`; enable when actively authoring `.tf`.
3. Provider docs — [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs).
4. tf-pilot ([TemplateMechanics/tf-pilot](https://github.com/TemplateMechanics/tf-pilot)) for non-Dynatrace Terraform questions (state strategy, multi-cloud, OPA policy patterns) — dt-pilot inherits the discipline but covers only Dynatrace specifics.

Never invent provider argument names from training data. Provider schemas change between releases; `terraform providers schema -json` is the live truth.
