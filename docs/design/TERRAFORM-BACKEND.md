# Design 003 — Terraform backend

| Field | Value |
|---|---|
| **Status** | Implemented (#15) |
| **Owner** | TBA |
| **Last updated** | 2026-05-22 |
| **Implementation PR** | [#15](https://github.com/TemplateMechanics/dt-pilot/pull/15) |
| **Depends on** | [Design 001](MULTI-BACKEND-SKELETON.md) (Implemented #10) |

## Problem

Many Dynatrace estates are already declared in Terraform via the official [`dynatrace-oss/dynatrace`](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest) provider. Today, those estates either:

1. Run Terraform completely outside dt-pilot's discipline (no enforced plan-before-apply review, no Copilot review loop, no MCP-first reads, no secret-hygiene scanner on the auth env).
2. Use the existing [tf-pilot](https://github.com/TemplateMechanics/tf-pilot) harness, which covers Terraform broadly (multi-provider) but doesn't ship the Dynatrace-specific affordances (DQL via Dynatrace MCP, the alerting/SLO/management-zone scaffolds, the agent personas tuned for Dynatrace).

Neither path is ideal for a team that wants Terraform-driven Dynatrace estate management AND dt-pilot's Dynatrace-specific guardrails. Worse, teams running both Monaco (for settings 2.0) and Terraform (for legacy classic configs or for the platform-level Dynatrace ActiveGate / OneAgent provisioning) currently have to maintain two harnesses.

After [Design 001](MULTI-BACKEND-SKELETON.md) lands the multi-backend skeleton, adding Terraform is a focused, bounded change.

## Goals

- **Cherry-pick from tf-pilot, don't fork it.** The tf-pilot wrappers, agent persona, and skill doc already exist and are battle-tested. Reuse what fits; adapt names to dt-pilot's conventions; cite tf-pilot as upstream so future improvements flow back.
- **Cover the Dynatrace use cases tf-pilot doesn't specialize in.** Per-resource scaffolds for `dynatrace_alerting`, `dynatrace_management_zone_v2`, `dynatrace_slo_v2`, `dynatrace_notification`, etc., in `modules/terraform/configs/<resource-type>/`.
- **Identical contract.** Plan-as-artifact (`tfplan` + `tfplan.json`), apply requires `-PlanFile`, destroy requires `-Confirm`, workspace-hash binding on the plan. Same Pester rejection paths as Monaco.
- **MCP integration is reused, not duplicated.** The Dynatrace MCP server is already the read surface; Terraform plans don't need a separate discovery layer. Add the Terraform MCP server (`hashicorp/terraform-mcp-server`) as a second `.vscode/mcp.json` entry for registry / provider docs.

## Non-goals

- Reimplementing every tf-pilot capability (state management, multi-cloud catalog reflection, YAML-token registry, OPA policy gate). Those stay in tf-pilot; teams that want them can pull tf-pilot in alongside dt-pilot. dt-pilot's Terraform backend covers the Dynatrace path.
- Supporting Terragrunt, Atlantis, or HCP Terraform Cloud-specific workflows. Plain Terraform CLI only.
- Auto-generating a reflected catalog from the Dynatrace provider schema in this PR. That's a follow-on equivalent to [Design 002](SCHEDULED-CATALOG-REFRESH.md) but for `terraform providers schema -json` output; deferred until the manual catalog is proven useful.

## Proposed design

### Directory additions

```
skills/
  terraform/SKILL.md          # NEW. Dynatrace-Terraform-specific reference.
                              # Defers to skills/iac/SKILL.md for the contract.
scripts/
  terraform/
    _Common.ps1               # Terraform-specific helpers (terraform exe
                              # resolution, plan metadata schema, lock-file
                              # awareness). Mirrors scripts/monaco/_Common.ps1
                              # in spirit; shares scripts/_Common.ps1 root.
    Initialize-TerraformWorkspace.ps1
    Invoke-TerraformPlan.ps1
    Invoke-TerraformApply.ps1
    Invoke-TerraformDestroy.ps1
    Validate-Terraform.ps1
    Get-TerraformVersion.ps1
    Sync-TerraformCatalog.ps1
config/catalog/
  terraform.json              # NEW. Catalog of dynatrace_* resource scaffolds.
  backends.json               # UPDATED. Add the 'terraform' entry.
modules/terraform/configs/
  alerting/dynatrace_alerting/{SCAFFOLD.md,main.tf.example,variables.tf.example}
  topology/dynatrace_management_zone_v2/...
  alerting/dynatrace_slo_v2/...
  alerting/dynatrace_notification/...
  topology/dynatrace_autotag_v2/...
  (initial set: 5-8 resources, same vibe as the Monaco catalog)
agents/
  terraform.agent.md          # NEW. Persona; defers to chief-systems-engineer
                              # for cross-cutting decisions, same as Dynatrace persona.
examples/
  terraform-baseline/
    versions.tf
    providers.tf
    main.tf                   # management zone -> alerting -> SLO + notification,
                              # matching the Monaco example's shape so reviewers
                              # can diff approach against approach.
    envs/dev.tfvars
    envs/prod.tfvars
    README.md
docs/
  TERRAFORM-DYNATRACE-INTEGRATION.md   # High-level: when to pick TF vs Monaco,
                                       # how the two coexist on one tenant.
.vscode/mcp.json              # UPDATED. Add 'terraform' MCP entry (off by
                              # default, like context7).
.vscode/mcp.servers.catalog.json   # UPDATED. Add 'terraform' entry.
```

### Plan artifact — `dt-pilot.tfplan/v1`

Mirrors the Monaco `dt-pilot.dryrun/v1` envelope:

```json
{
  "schema": "dt-pilot.tfplan/v1",
  "createdAtUtc": "2026-05-20T17:00:00Z",
  "environment": "dev",
  "workingDir": "examples/terraform-baseline",
  "workspaceHash": "<sha256 over .tf files + .tfvars + .terraform.lock.hcl>",
  "terraformVersion": "1.10.0",
  "terraformExe": "/usr/local/bin/terraform",
  "exitCode": 0,
  "summary": {
    "wouldAdd": 4,
    "wouldChange": 0,
    "wouldDestroy": 0
  },
  "planBinary": "tfplan",
  "planJsonSummary": "<truncated terraform show -json tfplan output>"
}
```

`Invoke-TerraformPlan.ps1` writes both the binary `tfplan` (consumed by `terraform apply tfplan`) AND this JSON envelope (consumed by `Invoke-TerraformApply.ps1` for the same identity / freshness / workspace-hash gates the Monaco wrapper enforces). The two artifacts travel together — losing the binary `tfplan` invalidates the deploy.

### Auth integration

The harness keeps its canonical environment variables (`DT_ENVIRONMENT`, `DT_PLATFORM_TOKEN`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`) as the user-facing surface a developer or CI job sets. The Terraform Dynatrace provider expects different names (`DT_ENV_URL`, `DT_API_TOKEN`, `DT_CLIENT_ID`, `DT_CLIENT_SECRET`, `DT_ACCOUNT_ID`). The wrappers translate at runtime:

- `Invoke-TerraformPlan.ps1` / `Invoke-TerraformApply.ps1` read the canonical env vars at start, then export the provider-specific names into the child Terraform process. The user sets the harness names once; the wrappers translate per-backend.
- The committed Terraform's provider block references only the provider-specific names; users never need to look at those names to operate dt-pilot.
- `docs/AUTHENTICATION.md` carries a reference table of the canonical -> provider-specific mapping for the rare case of running Terraform outside the wrappers (not supported but readable).

The committed Terraform pulls every credential from env vars; no hardcoded tokens. `Test-McpConfigSecrets.ps1` already scans for `dt0` token literals — its JSON-aware scanner would need an extension to also scan committed `.tf` files. That extension is part of this PR.

### MCP additions

One entry added to `.vscode/mcp.json` (the existing `dynatrace` MCP server stays as-is and serves the read path for both backends):

```json
"terraform": {
  "type": "stdio",
  "command": "pwsh",
  "args": ["-NoProfile", "-File", "${workspaceFolder}/scripts/terraform/Start-TerraformMcpServer.ps1"],
  "disabled": true
}
```

Plus a matching entry in `.vscode/mcp.servers.catalog.json` so the toggle and readiness scripts treat it identically to the Dynatrace server.

Off by default; the routing rule in `CLAUDE.md` (Design 001) flips it on when the workspace contains `*.tf` files via `Sync-McpServerEnablement.ps1` (also Design 001).

### Pester additions

A new `tests/Terraform.Tests.ps1` file (or a `Describe 'Terraform backend'` block in the existing Harness suite) covering, at minimum:

- `Resolve-TerraformExe` precedence (explicit > `TF_EXE` env > PATH).
- `Get-TerraformWorkspaceHash` is stable across re-reads and changes on `.tf` edit.
- Plan-metadata round-trip via `dt-pilot.tfplan/v1`.
- `Invoke-TerraformApply.ps1` rejection paths: missing plan binary, missing plan JSON, environment mismatch, workspace-hash mismatch, stale plan (> -MaxAgeMinutes).
- `Invoke-TerraformDestroy.ps1` refuses without `-Confirm`.
- Manifest-level secret scan: extension to `Test-McpConfigSecrets.ps1` flags a token literal in a committed `.tf`.

All hermetic; no real Terraform binary needed (use a fake `-TerraformExe` path that satisfies the file-exists check; every test exercises a rejection that fires before the binary is invoked).

## Migration / rollout

| Step | What |
|---|---|
| 1 | [Design 001](MULTI-BACKEND-SKELETON.md) implementation merged |
| 2 | This proposal merges as `Draft` (per the lifecycle in [`docs/design/README.md`](README.md), status flips happen in the implementation PR, not the proposal PR) |
| 3 | Implementation PR opens; first commit flips Status to `Accepted`; final commit flips to `Implemented (#<PR>)`. Body: skill, scripts, catalog entries, modules, example, agent persona, MCP entries, Pester tests |
| 4 | `Pre-Commit.ps1` already iterates `backends.json` (Design 001), so picks up Terraform's catalog `-Check` automatically |
| 5 | CI's pre-commit-gate validates the new wrappers without needing Terraform installed on the runner; if we want a real `terraform plan` exercise in CI, that's a separate `terraform-validate` job analogous to the originally-removed Monaco one, with the same credential-gating considerations |

## Alternatives considered

- **Fold dt-pilot into tf-pilot.** Rejected: tf-pilot is broader-scope (multi-cloud, multi-provider). dt-pilot is Dynatrace-vertical. The two have different agent personas, different MCP surfaces, different example shapes. Sharing patterns is healthy; merging codebases would dilute both.
- **Re-export tf-pilot wrappers as-is** under `scripts/terraform/`. Rejected: the wrapper names and parameter shapes differ between the two repos (tf-pilot uses `-VarFile`; we'd want `-VarFile` too but also need to match dt-pilot's `-MaxAgeMinutes` / `-DryRunFile`-equivalent gating). Direct re-export creates two slightly-different invocation surfaces that would diverge over time. Better to fork with attribution.
- **Skip per-resource scaffolds; rely on the provider docs.** Rejected: that's the same anti-pattern as not curating the Monaco catalog. Scaffolds give the agent a starting point that exercises dt-pilot's conventions (TODO markers, env-var references, parameterization).
- **Auto-generate scaffolds from `terraform providers schema -json`** for the `dynatrace` provider on day one. Rejected for this PR; it's a Design 002 equivalent for Terraform that comes later. Hand-curated initial set first to prove the shape.

## Open questions

1. **Resource version policy.** The provider exposes both `dynatrace_management_zone` (classic) and `dynatrace_management_zone_v2` (settings 2.0). Default: prefer `_v2` everywhere; document `_v1` as legacy in the skill. Confirm.
2. **HCL formatting via `terraform fmt`.** Should the pre-commit gate run `terraform fmt -check`? Requires Terraform installed locally (the rest of the gate doesn't). Proposal: yes if we add a `--no-fmt` opt-out, otherwise tf-fmt drift is endless.
3. **State management.** Default state-storage recommendation for the example? Local for the example (with a note that real projects use remote state)? Or ship an S3/Azure-blob example backend? Proposal: local for the example, remote-state guidance in `TERRAFORM-DYNATRACE-INTEGRATION.md`, no committed remote-state credentials of any kind.
4. **Where do `.tfvars` with developer-specific values live?** Proposal: `envs/dev.tfvars` committed for shareable values; `envs/dev.local.tfvars` gitignored for per-developer secrets/overrides — same pattern as `.vscode/mcp.session.json`.
5. **Do we vendor a copy of tf-pilot's `policy/terraform/plan.rego`** for the dt-pilot Terraform backend, or leave policy out of scope here? Proposal: leave it out; an `feat/terraform-policy-gate` follow-up can pull it in.

## Acceptance criteria

The implementation PR is mergeable when **all** of the following hold:

- [ ] Design 001 has already merged.
- [ ] `skills/terraform/SKILL.md` exists; defers to `skills/iac/SKILL.md` for the contract; covers Dynatrace-provider-specific resource patterns.
- [ ] `agents/terraform.agent.md` exists; mirrors the structure of `agents/dynatrace.agent.md`.
- [ ] `scripts/terraform/` contains at minimum: `_Common.ps1`, `Initialize-TerraformWorkspace.ps1`, `Validate-Terraform.ps1`, `Invoke-TerraformPlan.ps1`, `Invoke-TerraformApply.ps1`, `Invoke-TerraformDestroy.ps1`, `Get-TerraformVersion.ps1`, `Sync-TerraformCatalog.ps1`.
- [ ] `config/catalog/terraform.json` exists with at least 5 `dynatrace_*` resource scaffolds; `config/catalog/backends.json` lists the terraform backend.
- [ ] `modules/terraform/configs/` is populated by `Sync-TerraformCatalog.ps1`, byte-deterministic across PS editions, gated by `-Check` in `Pre-Commit.ps1`.
- [ ] `examples/terraform-baseline/` is a working stack mirroring `examples/baseline-stack/`'s shape (management zone → alerting → SLO + notification).
- [ ] `Test-McpConfigSecrets.ps1` extension covers `*.tf` token-literal detection; tested by Pester.
- [ ] Pester suite covers every Terraform-wrapper rejection path equivalent to Monaco's.
- [ ] `.vscode/mcp.json` includes a disabled `terraform` MCP entry; the catalog lists it; toggling works via `Set-McpServerState.ps1`.
- [ ] `docs/TERRAFORM-DYNATRACE-INTEGRATION.md` explains when to pick Terraform vs Monaco and how they coexist on one tenant.
- [ ] `docs/AUTHENTICATION.md` extended with the Terraform-provider env-var mapping.
- [ ] CHANGELOG updated; cross-references tf-pilot as upstream-inspiration.
