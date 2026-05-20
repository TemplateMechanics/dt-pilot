# dt-pilot

**dt-pilot** is an AI-powered development harness for Dynatrace configuration-as-code in VS Code. It bridges the gap between AI coding assistants (Claude Code, GitHub Copilot, Cursor, Codex) and the Dynatrace platform by providing structured instructions, automation scripts, validation tooling, and reference material.

Modeled on [TemplateMechanics/tf-pilot](https://github.com/TemplateMechanics/tf-pilot).

## What problem does this solve?

LLMs are confidently wrong about Dynatrace. They invent settings schema keys, skip dry-run before deploy, deploy across the wrong environment group, mishandle deletefiles, and produce manifests that fail Monaco's strict schema. dt-pilot is a *harness* in the Mitchell-Hashimoto sense: it engineers the environment so the agent cannot easily make those mistakes.

It does this with three things:

1. **Instructions** that tell the AI exactly how to behave on this codebase (`CLAUDE.md`, `.github/copilot-instructions.md`, `agents/dynatrace.agent.md`).
2. **A single authoritative skill reference** the AI reads before editing (`skills/dynatrace/SKILL.md`).
3. **Wrapped automation** the AI is required to use instead of typing `monaco` commands directly (`scripts/*.ps1`).

It also includes an **official Dynatrace MCP server integration** so agents can query DQL, problems, vulnerabilities, and entity context with first-party tooling before mutating configuration.

## Architecture

dt-pilot is designed as a layered control plane around Dynatrace's Monaco CLI, not just a set of helper scripts. The key design choice is split responsibility:

- **Read/discovery path:** Dynatrace MCP server (DQL, entities, problems, docs)
- **Write/mutation path:** guarded scripts with explicit dry-run/deploy gates

That split keeps agents fast at lookup while making mutation workflows deterministic and auditable.

```text
User request
  -> Agent instructions (CLAUDE.md / .github/copilot-instructions.md / agents/dynatrace.agent.md)
  -> Authoritative skill (skills/dynatrace/SKILL.md)
  -> Discovery (Dynatrace MCP server, docs/, reflected config catalog)
  -> Mutation via wrappers (scripts/*.ps1 only)
  -> Monaco outputs (dry-run summary + deploy log)
  -> Quality gates (manifest schema, config schema, deletefile review)
  -> CI sync checks and merge gates
```

### Instruction layering

1. `CLAUDE.md` / `.github/copilot-instructions.md`: operational safety rules and workflow constraints
2. `agents/dynatrace.agent.md`: conversational persona and behavior defaults
3. `skills/dynatrace/SKILL.md`: deep, authoritative Monaco + DQL reference
4. `docs/`: design references and operational playbooks
5. `examples/`: executable examples that validate expected patterns

## What's innovative here

1. **Dry-run-as-artifact discipline**
   `Invoke-MonacoDryRun.ps1` emits a saved dry-run summary; `Invoke-MonacoDeploy.ps1` requires `-DryRunFile`. Change review is explicit and repeatable.
2. **Deletefile review gate**
   Monaco's `delete` requires a generated deletefile. `Invoke-MonacoDelete.ps1` requires `-Confirm` and refuses to proceed without an explicit deletefile path.
3. **MCP-first reads, scripts-only writes**
   Agent workflows use the Dynatrace MCP server for DQL and entity context and wrappers for mutations to avoid direct, unsafe CLI behavior.
4. **Reflected config catalog**
   `config/catalog/` enumerates supported Monaco config types; `Sync-ConfigCatalog.ps1` regenerates scaffolds under `modules/configs/`, and CI enforces sync state.
5. **Branch + PR discipline enforced in instructions**
   The harness instructions forbid direct commits to `main` for both humans and agents. Every change goes via a semantic branch and squash-merged PR.

## Quick start

1. Fork or clone this repository into your Dynatrace configuration-as-code project root.
2. Open the project in VS Code with the [YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml) installed.
3. Install the supporting CLIs (PowerShell 7+, [Monaco CLI](https://github.com/Dynatrace/dynatrace-configuration-as-code), Node.js 20+ for the Dynatrace MCP server).
4. Provision Dynatrace credentials — see [`docs/AUTHENTICATION.md`](docs/AUTHENTICATION.md). The harness expects either a platform token (`DT_PLATFORM_TOKEN`) or OAuth credentials (`OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET`) in environment variables — never in checked-in files.
5. Talk to your AI assistant in natural language. It will read `CLAUDE.md` (or `.github/copilot-instructions.md`) and follow the operational sequence.
6. Configure MCP via `.vscode/mcp.json` (included).
7. Before pushing changes, run `./scripts/Pre-Commit.ps1` for the local quality gate.

## The mandatory dry-run / deploy discipline

> **WARNING:** dt-pilot enforces a dry-run-before-deploy, never-deploy-without-saved-dry-run discipline. The AI will refuse to call `monaco deploy` without first calling `Invoke-MonacoDryRun.ps1`, presenting the change summary, and waiting for explicit user approval. `monaco delete` is even more guarded — it requires both a generated deletefile and an explicit `-Confirm` flag.

## Branch and merge discipline

> dt-pilot was built end-to-end on its own branch + PR workflow. **The `main` branch is never committed to directly.** Every change — even bootstrap commits — goes on a semantic branch (`feat/...`, `fix/...`, `chore/...`, `docs/...`) and is squash-merged via a GitHub PR. See [`docs/BRANCH-WORKFLOW.md`](docs/BRANCH-WORKFLOW.md).

## Requirements

- [Monaco CLI](https://github.com/Dynatrace/dynatrace-configuration-as-code) `>= 2.18`
- PowerShell `7.0+` (cross-platform; `pwsh`)
- Node.js `>= 20` (for the Dynatrace MCP server)
- VS Code with the **YAML** extension
- A Dynatrace SaaS or Managed environment with a platform token or OAuth client

## What you don't have to do

| You normally have to | dt-pilot does for you |
|---|---|
| Memorize Dynatrace settings schema IDs | MCP + reflected config catalog provide schema discovery |
| Remember every Monaco command + flag | `./scripts/Invoke-Monaco*.ps1` wraps the lifecycle |
| Risk direct `monaco deploy` behavior | `Invoke-MonacoDeploy.ps1` requires a saved dry-run file |
| Risk direct `monaco delete` behavior | `Invoke-MonacoDelete.ps1` requires a deletefile + `-Confirm` |
| Catch manifest errors late | `.vscode/schemas/monaco-manifest.schema.json` + `Test-MonacoManifest.ps1` catch issues early |
| Manually maintain config-type drift | CI sync checks fail when reflected catalog outputs are stale |
| Hand-craft DQL queries | Dynatrace MCP generates and explains DQL |

## How a request flows through this harness

1. User asks for a change in chat.
2. Agent loads instruction files and safety rules.
3. Agent consults `skills/dynatrace/SKILL.md` before editing.
4. Agent discovers environment context with Dynatrace MCP (entities, current settings, DQL).
5. Agent creates a semantic branch (`feat/<scope>`).
6. Agent edits Monaco YAML/JSON with repository patterns.
7. Agent runs validation wrappers (`Validate-Monaco.ps1`, manifest schema check).
8. Agent runs `Invoke-MonacoDryRun.ps1` and presents the change summary.
9. User approves deploy explicitly.
10. Agent runs `Invoke-MonacoDeploy.ps1 -DryRunFile ...`.
11. Agent opens a PR; CI re-validates; squash-merge.

## Layout

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Instructions loaded by Claude Code |
| `.github/copilot-instructions.md` | Instructions loaded by GitHub Copilot |
| `agents/dynatrace.agent.md` | Conversational agent persona |
| `skills/dynatrace/SKILL.md` | Authoritative Monaco + DQL reference |
| `docs/` | Deep-dive references (auth, DQL primer, MCP integration, dry-run strategy, branch workflow) |
| `.vscode/mcp.json` | Workspace MCP integration (Dynatrace MCP + optional doc servers) |
| `.vscode/schemas/monaco-manifest.schema.json` | JSON Schema contract for `manifest.yaml` |
| `scripts/` | PowerShell wrappers for init/validate/dry-run/deploy/delete/download |
| `config/catalog/` | Reflected catalog of supported Monaco config types |
| `modules/configs/` | Generated config scaffolds (committed, sync-checked by CI) |
| `examples/baseline-stack/` | Working Monaco project (management zone + alerting profile + SLO + dashboard) |
| `policy/` | Policy rules evaluated against dry-run summaries |
| `tests/Harness.Tests.ps1` | Pester suite for the wrappers |
| `.github/workflows/validate.yml` | CI: validate + manifest schema + reflected catalog sync + tests |

## Generated Artifacts Governance

Reflected config catalog artifacts under `modules/configs/` and `config/catalog/` are intentionally committed and protected by CI sync checks.

Use commit-and-gate workflow:
1. Regenerate with the provided scripts.
2. Commit generated output in the same change.
3. Rely on CI sync checks to detect stale generated files.

## License

MIT — see [LICENSE](LICENSE).
