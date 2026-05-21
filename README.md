# dt-pilot

**dt-pilot** is an AI-powered development harness for Dynatrace configuration-as-code in VS Code. It bridges the gap between AI coding assistants (Claude Code, GitHub Copilot, Cursor, Codex) and the Dynatrace platform by providing structured instructions, automation scripts, validation tooling, and reference material.

Modeled on [TemplateMechanics/tf-pilot](https://github.com/TemplateMechanics/tf-pilot).

> **Status:** This README describes the **target** shape of dt-pilot. The repository is being built up across a series of small, reviewable PRs. Paths and scripts referenced below that are not yet present in the working tree are explicitly marked **(planned — lands in PR&nbsp;N)** and will be introduced in subsequent PRs.

## What problem does this solve?

LLMs are confidently wrong about Dynatrace. They invent settings schema keys, skip dry-run before deploy, deploy across the wrong environment group, mishandle deletefiles, and produce manifests that fail Monaco's strict schema. dt-pilot is a *harness* in the Mitchell-Hashimoto sense: it engineers the environment so the agent cannot easily make those mistakes.

It does this with three things:

1. **Instructions** that tell the AI exactly how to behave on this codebase (`CLAUDE.md`, `.github/copilot-instructions.md`, `agents/dynatrace.agent.md` — **planned, lands in PR&nbsp;2**).
2. **A single authoritative skill reference** the AI reads before editing (`skills/dynatrace/SKILL.md` — **planned, lands in PR&nbsp;3**).
3. **Wrapped automation** the AI is required to use instead of typing `monaco` commands directly (`scripts/*.ps1` — **planned, lands in PR&nbsp;4**).

It also includes an **official Dynatrace MCP server integration** so agents can query DQL, problems, vulnerabilities, and entity context with first-party tooling before mutating configuration (**planned, lands in PR&nbsp;5**).

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

1. **Dry-run-as-artifact discipline** *(planned, PR&nbsp;4)*
   `Invoke-MonacoDryRun.ps1` emits a saved dry-run summary; `Invoke-MonacoDeploy.ps1` requires `-DryRunFile`. Change review is explicit and repeatable.
2. **Deletefile review gate** *(planned, PR&nbsp;4)*
   Monaco's `delete` requires a generated deletefile. `Invoke-MonacoDelete.ps1` requires `-Confirm` and refuses to proceed without an explicit deletefile path.
3. **MCP-first reads, scripts-only writes** *(planned, PR&nbsp;5)*
   Agent workflows use the Dynatrace MCP server for DQL and entity context and wrappers for mutations to avoid direct, unsafe CLI behavior.
4. **Reflected config catalog** *(planned, PR&nbsp;8)*
   `config/catalog/` enumerates supported Monaco config types; `Sync-ConfigCatalog.ps1` regenerates scaffolds under `modules/configs/`, and CI enforces sync state.
5. **Branch + PR discipline enforced in instructions** *(in place from PR&nbsp;1)*
   The harness forbids direct commits to `main` for both humans and agents — see [`docs/BRANCH-WORKFLOW.md`](docs/BRANCH-WORKFLOW.md). Agent-facing instruction files that reinforce this rule land in PR&nbsp;2. Every change goes via a semantic branch and squash-merged PR.

## Quick start

> The steps below describe the **target** onboarding flow. Items marked **(planned)** are not present in `main` at the time of this PR — they land in the subsequent PRs noted in the [Layout](#layout) table.

1. Fork or clone this repository into your Dynatrace configuration-as-code project root.
2. Open the project in VS Code with the [YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml) installed.
3. Install the supporting CLIs (PowerShell 7+, [Monaco CLI](https://github.com/Dynatrace/dynatrace-configuration-as-code), Node.js 20+ for the Dynatrace MCP server).
4. Provision Dynatrace credentials — see `docs/AUTHENTICATION.md` **(planned, lands in PR&nbsp;8)**. The harness expects either a platform token (`DT_PLATFORM_TOKEN`) or OAuth credentials (`OAUTH_CLIENT_ID` + `OAUTH_CLIENT_SECRET`) in environment variables — never in checked-in files.
5. Talk to your AI assistant in natural language. It will read `CLAUDE.md` (or `.github/copilot-instructions.md`) **(planned, lands in PR&nbsp;2)** and follow the operational sequence.
6. Configure MCP via `.vscode/mcp.json` **(planned, lands in PR&nbsp;5)**.
7. Before pushing changes, run `./scripts/Pre-Commit.ps1` **(planned, lands in PR&nbsp;6)** for the local quality gate.

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
| Remember every Monaco command + flag | `./scripts/monaco/Invoke-Monaco*.ps1` wraps the lifecycle |
| Risk direct `monaco deploy` behavior | `Invoke-MonacoDeploy.ps1` requires a saved dry-run file |
| Risk direct `monaco delete` behavior | `Invoke-MonacoDelete.ps1` requires a deletefile + `-Confirm` |
| Catch manifest errors late | `.vscode/schemas/monaco-manifest.schema.json` + `Test-MonacoManifest.ps1` catch issues early |
| Manually maintain config-type drift | CI sync checks fail when reflected catalog outputs are stale |
| Hand-craft DQL queries | Dynatrace MCP generates and explains DQL |

## How a request flows through this harness

> The flow below describes the **target** behavior once all PRs in the bootstrap series have landed. Steps 4–10 depend on tooling introduced in PRs 2–6.

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

The table below lists the **target** layout. The third column tracks the PR in the bootstrap series that introduces each path.

| Path | Purpose | Status |
|---|---|---|
| `README.md` | This file | **present (PR&nbsp;1)** |
| `LICENSE` | MIT license | **present (PR&nbsp;1)** |
| `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` | Contribution + security policy | **present (PR&nbsp;1)** |
| `.github/pull_request_template.md` | PR template | **present (PR&nbsp;1)** |
| `docs/BRANCH-WORKFLOW.md` | Never-commit-to-main + squash-only policy | **present (PR&nbsp;1)** |
| `CLAUDE.md` | Instructions loaded by Claude Code | planned (PR&nbsp;2) |
| `.github/copilot-instructions.md` | Instructions loaded by GitHub Copilot | planned (PR&nbsp;2) |
| `agents/dynatrace.agent.md` | Conversational agent persona | planned (PR&nbsp;2) |
| `skills/dynatrace/SKILL.md` | Authoritative Monaco + DQL reference | planned (PR&nbsp;3) |
| `docs/DQL-PRIMER.md` | DQL primer | planned (PR&nbsp;3) |
| `scripts/` | PowerShell wrappers for init/validate/dry-run/deploy/delete/download | planned (PR&nbsp;4) |
| `.vscode/mcp.json` | Workspace MCP integration (Dynatrace MCP + optional doc servers) | planned (PR&nbsp;5) |
| `.vscode/schemas/monaco-manifest.schema.json` | JSON Schema contract for `manifest.yaml` | planned (PR&nbsp;5) |
| `.github/workflows/validate.yml` | CI: validate + manifest schema + reflected catalog sync + tests | planned (PR&nbsp;6) |
| `scripts/Pre-Commit.ps1` | Local quality gate | planned (PR&nbsp;6) |
| `tests/Harness.Tests.ps1` | Pester suite for the wrappers | planned (PR&nbsp;6) |
| `examples/baseline-stack/` | Working Monaco project (management zone + alerting profile + SLO + dashboard) | planned (PR&nbsp;7) |
| `config/catalog/` | Reflected catalog of supported Monaco config types | planned (PR&nbsp;8) |
| `modules/configs/` | Generated config scaffolds (committed, sync-checked by CI) | planned (PR&nbsp;8) |
| `policy/` | Policy rules evaluated against dry-run summaries | planned (PR&nbsp;8) |
| `docs/AUTHENTICATION.md`, `docs/RUNBOOK.md` | Auth setup + operational runbook | planned (PR&nbsp;8) |

## Generated Artifacts Governance

Reflected config catalog artifacts under `modules/configs/` and `config/catalog/` are intentionally committed and protected by CI sync checks.

Use commit-and-gate workflow:
1. Regenerate with the provided scripts.
2. Commit generated output in the same change.
3. Rely on CI sync checks to detect stale generated files.

## License

MIT — see [LICENSE](LICENSE).
