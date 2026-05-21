# Reflected Config Catalog — Coverage Doctrine

The reflected config catalog (`config/catalog/catalog.settings.json` + the generated `modules/configs/<family>/<safe-id>/` scaffolds) is dt-pilot's curated inventory of Dynatrace configuration types we ship a starting-point scaffold for. This document is the canonical doctrine for what belongs in the catalog, what the scaffolds guarantee, and how the sync check works.

## What the catalog is — and isn't

**Is:**
- A curated list of common Dynatrace settings 2.0 schemas and classic-API config types.
- The source of truth for the scaffolds under `modules/configs/`. Hand-edits to generated files are overwritten on the next `Sync-ConfigCatalog.ps1` run; the only way to change a scaffold is to change the catalog or the generator.
- A discovery aid for agents. When the user asks "do we have a starting point for SLOs?", the agent can answer by reading the catalog.

**Isn't:**
- A complete reflection of every Dynatrace schema. Dynatrace has hundreds; the catalog covers the most commonly authored ones plus a representative cross-section of families.
- A substitute for `monaco generate schema` when authoring a real config. The scaffolds intentionally use a placeholder `template.json` body — you replace it with the live schema-derived payload when you adopt the scaffold.
- A guarantee that a scaffold is currently valid against the live Dynatrace API. Schemas evolve; periodic regeneration against new releases is expected.

## The `<safe-id>` transformation

The catalog entry's `id` is a Dynatrace schema identifier (e.g. `builtin:problem.notifications` or `builtin:problem.notifications/email`) that contains `:` and `/`, neither of which is safe in every filesystem path. The generator transforms `id` to `<safe-id>` by replacing both characters with `-`:

| Catalog `id` | On-disk `<safe-id>` |
|---|---|
| `builtin:management-zones` | `builtin-management-zones` |
| `builtin:problem.notifications` | `builtin-problem.notifications` |
| `builtin:problem.notifications/email` | `builtin-problem.notifications-email` |

This is one-way; the generator owns the transformation. Don't try to author a config in a directory named with the raw `id` — the sync check would flag it as an orphan.

## What's in the catalog today

| Family | Schema ID | Display name |
|---|---|---|
| topology | `builtin:management-zones` | Management Zone |
| topology | `builtin:tags.auto-tagging` | Auto-Tag Rule |
| alerting | `builtin:alerting.profile` | Alerting Profile |
| alerting | `builtin:slo` | Service Level Objective |
| alerting | `builtin:problem.notifications` | Problem Notification |
| alerting | `builtin:problem.notifications/email` | Problem Notification — Email |
| alerting | `builtin:anomaly-detection.metric-events` | Metric-Event Anomaly Detection |
| visualization | `builtin:dashboards` | Dashboard |

Run `./scripts/monaco/Sync-ConfigCatalog.ps1` after editing the catalog and commit the regenerated `modules/configs/` files in the same PR.

## How to add an entry

1. Edit `config/catalog/catalog.settings.json` and add a new object to the `schemas` array. Required fields:
   - `id` — the Dynatrace schema ID (`builtin:...`) or a `parent/subtype` pair for per-channel notifications.
   - `family` — one of `topology`, `alerting`, `visualization`, `automation`, `security`, `account`, `misc`.
   - `displayName` — short human-readable name.
   - `scope` — `environment` is the right default; override only if the schema is host- / process-group- / entity-scoped by nature.
   - `summary` — one or two sentences. This text shows up in the generated `SCAFFOLD.md`.
   - `commonParameters` *(optional)* — the parameter names the generator should pre-declare in the scaffold's `config.yaml`. Pick the parameters you'd genuinely want to be named (a `name`, a reference to another config, a numeric threshold) — not every field of the underlying schema.
2. Run `./scripts/monaco/Sync-ConfigCatalog.ps1` (no `-Check`) to regenerate the modules.
3. Commit both the catalog edit and the regenerated `modules/configs/...` files in the same PR.
4. The pre-commit gate (`Pre-Commit.ps1`) and CI's pre-commit-gate job run `Sync-ConfigCatalog.ps1 -Check`, which fails the PR if the modules drift from what the catalog would produce.

## What `-Check` enforces

`Sync-ConfigCatalog.ps1 -Check` regenerates the scaffolds into a temporary shadow directory and diffs them against `modules/configs/`. It fails if any of:

- A file the catalog would produce is **missing on disk**.
- A file on disk has **byte-different content** from the regeneration.
- A file is **orphan on disk** (no corresponding catalog entry — typically left over after removing a catalog entry without regenerating).

The check is byte-exact, so even whitespace changes count. Always go through `Sync-ConfigCatalog.ps1` (without `-Check`) to make scaffold changes — never hand-edit.

## What a scaffold guarantees

Every `modules/configs/<family>/<safe-id>/` directory contains three files:

| File | Purpose |
|---|---|
| `SCAFFOLD.md` | Human-readable rationale, scope, and adoption instructions. Carries the `GENERATED FILE` header. |
| `config.yaml.example` | Monaco `config.yaml` with the schema ID and scope pre-filled and the catalog's `commonParameters` pre-declared with `TODO-` placeholder values. Copy and rename to `config.yaml` when adopting. |
| `template.json.example` | Placeholder JSON body with `{{ .parameter }}` references for each `commonParameter`. **NOT a valid Dynatrace payload** — the user replaces it with the live schema-derived shape when adopting. |

The scaffold is intentionally minimal. Its job is to get the user past the "what fields does this schema even take?" hurdle and into the real authoring loop.

## Why "reflected" if the catalog is hand-maintained?

The name follows the tf-pilot convention where the catalog *is* a reflection of the provider schema. For Dynatrace, fully reflecting every settings 2.0 schema is out of scope — there are too many and they change too often — so the catalog is a hand-curated subset with the *intent* of reflecting the most commonly authored shapes. A future enhancement could auto-populate the catalog from `monaco generate schema` output across a list of schemas; until then, the catalog is curated.

## Regeneration cadence

Regenerate when:

- Adding or removing a catalog entry.
- Changing a `commonParameters` list.
- Updating the generator (`Sync-ConfigCatalog.ps1`) in a way that changes file shape — even cosmetic changes count for the `-Check` gate.

Don't regenerate just to "freshen" — the output is deterministic from the inputs, so an off-cycle regeneration with no input change should be a no-op.

## Generated-artifact governance recap

- Scaffolds under `modules/configs/` are **committed**, not gitignored, so consumers cloning the harness get them for free.
- They're protected by `Sync-ConfigCatalog.ps1 -Check` in the pre-commit gate and in CI.
- Hand-edits will be overwritten the next time the script runs. Don't hand-edit; fix the catalog or the generator.

See also: [`README.md` — Generated Artifacts Governance](../README.md), `agents/dynatrace.agent.md` refusal list (refuses to hand-edit `modules/configs/`).
