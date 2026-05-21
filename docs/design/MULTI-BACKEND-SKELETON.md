# Design 001 — Multi-backend skeleton

| Field | Value |
|---|---|
| **Status** | Draft |
| **Owner** | TBA |
| **Last updated** | 2026-05-20 |
| **Implementation PR** | _pending_ |

## Problem

dt-pilot today is Monaco-only. Real Dynatrace estates often need:

- **Terraform** for the Dynatrace provider (very common in enterprise tf shops; tf-pilot already covers it).
- **Crossplane** for K8s-native shops, both for Dynatrace itself and for the infrastructure being monitored.
- **Pulumi** for shops that picked Pulumi as their IaC tool (uses the TF-bridge `pulumi-dynatrace` package).

Today's structure conflates "the harness contract" (dry-run-before-deploy, deletefile gating, MCP-first reads, secret hygiene, branch/PR discipline) with "the Monaco implementation of that contract." Adding a second backend would require either:

1. Forking the harness per tool (`monaco-pilot`, `terraform-pilot`, `crossplane-pilot`, `pulumi-pilot`) — high duplication, drift between forks.
2. Bolting per-tool scripts under `scripts/` next to the Monaco ones — directory becomes a mess, agent instructions become an if/elif tree.

Neither is acceptable. We need to separate the contract from the implementation.

## Goals

- **Zero behavior change for existing Monaco users.** Every current script path keeps working at the same invocation; users can keep typing `./scripts/Invoke-MonacoDryRun.ps1 -Path examples/baseline-stack ...`.
- **A single place that defines the harness contract**, independent of tool. New backends "implement the contract" rather than re-deriving discipline from scratch.
- **Routing is deterministic from workspace shape**, not from chat preamble or per-PR config. The agent reads the rules once and routes correctly.
- **A new backend can be added in a single bounded PR** (skill doc + wrappers + catalog entry + a test). No cross-cutting refactors required.

## Non-goals

- Implementing the Terraform / Crossplane / Pulumi backends in this PR. Each is its own follow-up (Design 003 covers Terraform; Crossplane and Pulumi will get their own proposals when prioritized).
- Designing a generic IaC abstraction layer that could replace Terraform / Pulumi / Crossplane themselves. Backends are adapters, not abstractions.
- Cross-backend orchestration (a deploy that fans across Monaco + Terraform in one transaction). Out of scope; each backend operates independently.

## Proposed design

### Directory layout after the change

```
skills/
  iac/SKILL.md                # NEW. The tool-agnostic contract.
  dynatrace/SKILL.md          # Already exists. Monaco-specific.
  <future>/SKILL.md           # Terraform, Crossplane, Pulumi, ...
scripts/
  _Common.ps1                 # Stays at scripts/ root; tool-agnostic helpers.
  monaco/                     # NEW. Move every Invoke-Monaco*, Validate-Monaco,
                              # Test-MonacoManifest, Sync-ConfigCatalog under here.
  <future>/                   # Terraform, Crossplane, Pulumi wrappers go here.
config/catalog/
  backends.json               # NEW. Authoritative list of supported backends,
                              # what wrappers / docs / skill / catalog file each
                              # owns, and how the router detects each backend.
  catalog.settings.json       # Stays. Monaco-specific reflected catalog.
                              # Other backends bring their own catalog files
                              # under config/catalog/<backend>.json.
modules/configs/              # Stays. Monaco-only today; other backends emit
                              # their scaffolds under their own subtree
                              # (e.g. modules/terraform/) when they land.
```

### The harness contract — `skills/iac/SKILL.md`

This new doc defines the rules every backend must satisfy. Concretely:

1. **A "plan" or "dry-run" command** that produces a saved, reviewable artifact (a JSON sidecar or equivalent). Path convention: `dryrun/<env>.json` for Monaco's existing artifact, `tfplan` + `tfplan.json` for Terraform, etc. The artifact must record at minimum: backend, environment / target, source-content hash, timestamp, and the planned operations.
2. **An "apply" or "deploy" command** that **requires** the saved artifact as a `-PlanFile` / `-DryRunFile` parameter. The wrapper refuses to run without it; refuses to run if the artifact's source-content hash doesn't match the live workspace; refuses to run on an artifact older than `-MaxAgeMinutes`.
3. **A "delete" / "destroy" command** that requires explicit `-Confirm` AND, where the backend supports a deletefile / targeted-resource list, that list.
4. **Read-only discovery goes through MCP first.** The Dynatrace MCP server is the discovery surface regardless of backend (DQL, entities, problems, vulnerabilities). Backends that have their own MCP server (Terraform MCP, cloud MCPs) layer them in via `.vscode/mcp.json` and the existing catalog.
5. **Secrets via env vars; never committed.** The same `Test-McpConfigSecrets.ps1` scanner applies to every backend's per-developer config files.
6. **Branch + PR discipline + Copilot review loop.** Identical across backends.

A backend that satisfies the contract is conformant. `skills/<backend>/SKILL.md` only needs to document the backend-specific syntax — references to the contract live in the iac skill.

### Router rule in `CLAUDE.md`

A single section near the top, before "Key Rules":

> **Backend routing.** Before reading any backend-specific skill, detect which backend(s) apply to the current workspace by checking these signals in order:
>
> | If the workspace contains ... | Backend | Skill |
> |---|---|---|
> | `manifest.yaml` (Monaco manifest schema) | Monaco | `skills/dynatrace/SKILL.md` |
> | `*.tf` files at any level | Terraform | `skills/terraform/SKILL.md` |
> | `Composition` / `XRD` / `crossplane.yaml` | Crossplane | `skills/crossplane/SKILL.md` |
> | `Pulumi.yaml` | Pulumi | `skills/pulumi/SKILL.md` |
>
> Read every applicable backend's skill before editing files that belong to that backend. If multiple backends apply, read `skills/iac/SKILL.md` first for the cross-cutting contract.

The router is purely textual — no code change in any script. Agents read it, humans read it, both follow it.

### `config/catalog/backends.json` — backend registry

```json
{
  "version": "1.0",
  "backends": [
    {
      "id": "monaco",
      "displayName": "Dynatrace Monaco",
      "skill": "skills/dynatrace/SKILL.md",
      "scriptsDir": "scripts/monaco",
      "catalogFile": "config/catalog/catalog.settings.json",
      "modulesDir": "modules/configs",
      "detect": [
        { "type": "file-exists", "path": "manifest.yaml" },
        { "type": "file-exists-recursive", "glob": "**/manifest.yaml" }
      ]
    }
    /* terraform, crossplane, pulumi entries added by their own PRs */
  ]
}
```

`Pre-Commit.ps1` reads this file to pick which catalog `-Check`s to run and which wrappers to validate; agents read it to enumerate what's supported.

### Script reorganization mechanics

This is the part with real diff size. Three rules to keep the move boring:

1. **`git mv`** every script under `scripts/<backend>/`. Preserves history; reviewers can use `--follow` to trace blame across the move.
2. **Compatibility shims** at the original paths for the duration of one release cycle. `scripts/Invoke-MonacoDryRun.ps1` becomes a one-line wrapper that calls `scripts/monaco/Invoke-MonacoDryRun.ps1` with the same args, plus a deprecation warning to stderr telling the caller to update their invocation. Removed in the release after — call it a 30-day window.
3. **Cross-references in every doc.** `CLAUDE.md`, `agents/dynatrace.agent.md`, `skills/dynatrace/SKILL.md`, and `examples/baseline-stack/README.md` all point at the new paths. The shim handles muscle memory; the docs lead anyone reading fresh.

`_Common.ps1` stays at `scripts/` root and stays backend-agnostic. The dry-run-metadata schema (`dt-pilot.dryrun/v1`) becomes the canonical artifact format that all backends extend (a Terraform backend would write `dt-pilot.tfplan/v1`, a Crossplane backend `dt-pilot.crossplane-render/v1`, etc.).

## Migration / rollout

| Step | What | Who |
|---|---|---|
| 1 | This proposal merges as `Draft` (no status flip on the proposal-PR itself, per the lifecycle in [`docs/design/README.md`](README.md)) | Maintainer |
| 2 | Implementation PR opens; its first commit flips this doc's Status from `Draft` to `Accepted`. The implementation: `git mv` scripts, add `skills/iac/SKILL.md`, add `backends.json`, add router section to `CLAUDE.md`, add compatibility shims | Implementer |
| 2a | Implementation PR's final commit flips Status to `Implemented (#<PR>)` and updates the [proposal index](README.md) row | Implementer |
| 3 | Run `./scripts/Pre-Commit.ps1 -All` locally + CI; both must pass before merge | Implementer + reviewer |
| 4 | Update [`CHANGELOG.md`](../../CHANGELOG.md) under `[Unreleased]` with "moved scripts/* to scripts/monaco/* with deprecation shims" | Implementer |
| 5 | Open an issue: "Remove scripts/Invoke-Monaco*.ps1 compatibility shims" tagged for the next release | Implementer |

No data migration needed; no live Dynatrace touched.

## Alternatives considered

- **Per-tool repo forks (`monaco-pilot`, `tf-pilot`, ...).** Rejected: tf-pilot already exists and we're not killing it, but for the *combined* harness use-case (one team using both Monaco and Terraform against the same Dynatrace tenant), per-tool repos force the team to dual-vendor every shared piece (auth docs, MCP config, branch workflow). Single repo with adapters wins on coherence.
- **Single flat `scripts/` directory with prefixed names** (`scripts/Monaco-Invoke-DryRun.ps1`, `scripts/Terraform-Invoke-Plan.ps1`). Rejected: tab completion gets noisy quickly; per-backend Pester suites become hard to scope; the `_Common.ps1` injection point is less obvious.
- **A YAML-driven backend registry** (`backends.yaml`) instead of JSON. Rejected for consistency with the existing catalog (`catalog.settings.json`) and because the registry is consumed by scripts that already parse JSON natively.
- **Letting CLAUDE.md keep growing per backend**, without a separate `skills/iac/SKILL.md`. Rejected: `CLAUDE.md` is already at the limit of what an agent reliably internalizes per request; splitting the cross-cutting contract into its own short skill keeps the per-backend skills focused.

## Open questions

1. **Should the deprecation window for the wrapper shims be 30 days, one release, or one calendar quarter?** Default proposal: one release. Adjust based on consumer feedback.
2. **Do we need an explicit `backends.json` schema (`config/catalog/backends.schema.json`) on day one?** Proposal: yes — same pattern as the MCP catalog schema. Tiny file, big payoff for editor support.
3. **Where does the IaC contract reference live in agent personas?** The `agents/dynatrace.agent.md` and a future `agents/terraform.agent.md` will both want to defer to `skills/iac/SKILL.md` for the cross-cutting rules. The wording should be a one-liner in each persona, not duplicated.
4. **Does `Pre-Commit.ps1` learn to iterate over `backends.json` and call each backend's catalog `-Check`?** Proposal: yes, as part of the implementation. Otherwise the gate only validates Monaco's catalog forever.

## Acceptance criteria

The implementation PR is mergeable when **all** of the following hold:

- [ ] Every wrapper that lived at `scripts/Invoke-Monaco*.ps1`, `scripts/Validate-Monaco.ps1`, `scripts/Test-MonacoManifest.ps1`, `scripts/Initialize-MonacoWorkspace.ps1`, `scripts/Get-MonacoVersion.ps1`, `scripts/Sync-ConfigCatalog.ps1`, plus the MCP scripts where they're Monaco-specific, lives under `scripts/monaco/`.
- [ ] Compatibility shims exist at every original path and write a single-line deprecation warning to stderr on each invocation.
- [ ] `skills/iac/SKILL.md` exists, ≤ 400 lines, and `skills/dynatrace/SKILL.md` defers to it for the contract.
- [ ] `CLAUDE.md` has a Backend Routing section before Key Rules.
- [ ] `config/catalog/backends.json` exists with the `monaco` entry and a JSON Schema sibling.
- [ ] `Pre-Commit.ps1` iterates `backends.json` and runs each backend's `Sync-*Catalog.ps1 -Check`.
- [ ] All Pester tests pass; `examples/baseline-stack` validates via both the new path and the shim.
- [ ] CHANGELOG updated; deprecation removal issue filed and linked.
