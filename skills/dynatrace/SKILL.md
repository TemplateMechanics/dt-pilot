# Skill — Dynatrace Configuration-as-Code with Monaco

This is the canonical reference for working with Dynatrace configuration in this repository **using the Monaco backend**. It is one of several per-backend skills under `skills/<backend>/SKILL.md`. The cross-backend contract — plan-as-artifact, apply gates, destroy gates, secret hygiene, MCP-first reads, branch + PR discipline — lives in [`skills/iac/SKILL.md`](../iac/SKILL.md). Read that skill first if you have not; this document assumes you know the contract and covers Monaco's implementation of it.

Read this skill before editing any `manifest.yaml`, `config.yaml`, or `template.json`. When this document and external Dynatrace documentation conflict, the Dynatrace documentation wins for product behavior; this skill wins for repository conventions (file layout, parameter naming, branch/PR discipline).

Wrapper scripts referenced below live at `scripts/monaco/Invoke-Monaco*.ps1` (and similar). Compatibility shims at the legacy `scripts/Invoke-Monaco*.ps1` paths still work but emit a deprecation warning; update invocations to the new paths.

---

## 1. Monaco's three building blocks

Monaco is a deployment tool for Dynatrace configuration. Its model is:

1. **Deployment manifest** (`manifest.yaml`) — names the projects to deploy and the environments / environment groups to deploy them to.
2. **Project** — a folder of related configuration files. Lives under `projects/<project-name>/` (the path is configurable via the manifest, but the dt-pilot convention is `projects/<name>/`).
3. **Config + template pairs** — each Dynatrace configuration object is two files: a `config.yaml` describing identity, schema, scope, and parameters, plus a sibling `template.json` (or `.yml`) holding the actual API payload with `{{ .parameter }}` placeholders.

That's it. Everything else — references between configs, environment fan-out, partial deploys, deletefiles — is composition on top of those three primitives.

---

## 2. `manifest.yaml`

The deployment manifest is the root of every Monaco workspace. dt-pilot expects it at the repository root or at the root of a self-contained sub-project under `examples/`.

### Minimal example

Verbatim from the upstream Monaco test fixture (`Dynatrace/dynatrace-configuration-as-code` → `test/configuration/references/testdata/references/manifest.yaml`), lightly elided:

```yaml
manifestVersion: 1.0

projects:
  - name: classic-apis
  - name: settings
  - name: classic-with-settings-mngt-zone

environmentGroups:
  - name: default
    environments:
      - name: classic_env
        url:
          type: environment
          value: URL_ENVIRONMENT_1
        auth:
          token:
            name: TOKEN_ENVIRONMENT_1
      - name: platform_env
        url:
          type: environment
          value: PLATFORM_URL_ENVIRONMENT_2
        auth:
          token:
            name: TOKEN_ENVIRONMENT_2
          oAuth:
            clientId:
              name: OAUTH_CLIENT_ID
            clientSecret:
              name: OAUTH_CLIENT_SECRET
            tokenEndpoint:
              type: environment
              value: OAUTH_TOKEN_ENDPOINT
```

### Field-by-field

| Field | Required | Notes |
|---|---|---|
| `manifestVersion` | yes | Currently `1.0`. This is the **manifest schema version**, not the Monaco CLI version. The CLI is pinned separately (in CI; see PR&nbsp;6). |
| `projects[].name` | yes | Must match a directory under the manifest's working directory (`projects/<name>/` in dt-pilot's convention). |
| `projects[].path` | optional | Override if the directory name differs from the project name. Avoid using this — the cost is one extra indirection per project for no real benefit. |
| `projects[].type` | optional | Use `grouping` for an umbrella project that bundles sub-projects (rare). |
| `environmentGroups[].name` | yes | Logical grouping (`dev`, `non-prod`, `prod`). Deploys can target the group as a whole. |
| `environmentGroups[].environments[].name` | yes | One environment per Dynatrace tenant. |
| `environments[].url.type` | yes | `value` (literal) or `environment` (read from env var named in `.value`). dt-pilot strongly prefers `environment` so tenant URLs are not committed. |
| `environments[].url.value` | yes | The literal URL, or the env-var name if `type: environment`. |
| `environments[].auth.token.name` | optional | Env-var name holding a Dynatrace classic API token. Use for classic-config-API workflows only. |
| `environments[].auth.platformToken.name` | optional | Env-var name holding a Dynatrace platform token. Newer, scoped tokens for settings 2.0. |
| `environments[].auth.oAuth.clientId.name` / `.clientSecret.name` | optional | OAuth client credentials. **Required for account-management operations** (platform tokens and API tokens do not work for account-management). |
| `environments[].auth.oAuth.tokenEndpoint` | optional | Override the default OAuth token endpoint. Use `type: environment` to read from `OAUTH_TOKEN_ENDPOINT` when targeting a non-default SSO. |

### Auth-method decision matrix

| Workflow | Preferred auth |
|---|---|
| Settings 2.0 (alerting profiles, management zones, SLOs, notifications, dashboards via settings) | `platformToken` for local dev; `oAuth` for CI / production deploys |
| Classic config API (auto-tags, custom anomaly detection rules not yet in settings) | `token` (classic API token) |
| Account management (groups, policies, user assignments) | `oAuth` — required; nothing else works |
| Read-only DQL / entity queries via MCP | `oAuth` or `platformToken` — both work via the Dynatrace MCP server |

### Required OAuth scopes (minimum for settings 2.0 deploys)

- `app-engine:apps:run`
- `settings:objects:read`
- `settings:objects:write`
- `settings:schemas:read`

Add account-management scopes only when the project actually deploys account configs. The principle is: tokens get **exactly** the scope they need, never `*:*`.

---

## 3. The project layout

dt-pilot's convention:

```
projects/
  <project-name>/
    <schema-or-api>/
      config.yaml        # identity + parameters
      <template>.json    # API payload with {{ .parameter }} placeholders
```

The middle folder name (`<schema-or-api>`) is conventional and aids reviewer scanning — Monaco itself does not require it; it walks the project recursively and picks up every `config.yaml`. Pick whichever convention reviewers can scan fastest. dt-pilot's examples use the schema ID (e.g. `builtin:alerting.profile/`, `builtin:management-zones/`).

### `config.yaml`

Adapted from the upstream Monaco fixture (`test/configuration/references/testdata/references/settings/config.yaml`), reformatted to dt-pilot's 2-space indentation:

```yaml
configs:
  - id: profile
    type:
      settings:
        schema: builtin:alerting.profile
        scope: environment
    config:
      name: profile
      template: profile.json
      parameters:
        managementZoneId: [ builtin:management-zones, zone, id ]

  - id: zone
    type:
      settings:
        schema: builtin:management-zones
        scope: environment
    config:
      name: zone
      parameters:
        environment: environment1
        meId: HOST_GROUP-1234567890123456
      template: zone.json

  - id: slack
    type:
      settings:
        schema: builtin:problem.notifications
        scope: environment
    config:
      name: notification
      parameters:
        alertingProfileId: [ builtin:alerting.profile, profile, id ]
        environment: Env1
      template: slack.json
```

#### `configs[].id`

The Monaco-internal identifier for this config. **It is identity.** Renaming it creates a new config and orphans the old one in the live environment. Use `git mv` to rename the *file*; never rename `id` in place.

#### `configs[].type`

Two principal forms:

- `settings:` for settings 2.0 schemas. Requires `schema` (e.g. `builtin:alerting.profile`) and `scope` (`environment`, `host`, `host-group`, `process-group`, or a specific Monitored-Entity ID like `HOST_GROUP-1234...`).
- `api:` for classic config API endpoints (e.g. `auto-tag`). Used when settings 2.0 doesn't yet cover the surface. Prefer settings 2.0 when both exist.

There is also `automation:` for workflow / business-event / scheduling-rule configs and `bucket:` for Grail bucket definitions; see Monaco docs.

#### `configs[].config.name`

Human-readable name shown in the Dynatrace UI. Can be a string or a parameter reference.

#### `configs[].config.template`

Path (relative to `config.yaml`) of the JSON template file holding the API payload.

#### `configs[].config.parameters`

A map of parameter name → value. The keys map to `{{ .parameter }}` placeholders in the sibling template. Values can be any of the parameter types (next section).

#### `configs[].config.skip` (optional)

Boolean or environment-conditional that skips this config from deploy. Useful for "soft-disable" without deleting.

---

## 4. Parameter types

Monaco supports several parameter shapes. Each appears as the value of an entry under `configs[].config.parameters`.

### `value` (literal)

```yaml
parameters:
  delayMinutes: 5
  enabled: true
  tagFilter: "asdf\\:jkloe"
```

A bare scalar. The most common form.

### `environment` (read from an environment variable)

```yaml
parameters:
  region:
    type: environment
    name: DEPLOY_REGION
    default: us-east-1
```

Reads from the env var at deploy time. `default` is optional.

### `reference` (point at another config's output)

Two forms — both legal, the shorthand is more common in the wild:

**Shorthand (array form, used in the upstream fixture):**

```yaml
parameters:
  managementZoneId: [ builtin:management-zones, zone, id ]
```

The array is `[ <configType>, <configId>, <property> ]`.

**Long form (when you also need to cross a project boundary):**

```yaml
parameters:
  managementZoneId:
    type: reference
    project: shared-foundations
    configType: builtin:management-zones
    configId: zone
    property: id
```

When the referenced config lives in the same project, omit `project`. The `property` is almost always `id`, but other properties of the referenced config's response can be selected.

References produce implicit deploy ordering — Monaco computes a DAG and deploys dependencies before dependents.

### `compound` (build a value by templating other parameters)

```yaml
parameters:
  fullName:
    type: compound
    format: "{{ .prefix }}-{{ .suffix }}"
    references:
      - prefix
      - suffix
```

`format` is a Go template; `references` lists the other parameters it consumes (Monaco uses this to compute deploy order).

### `list` (multiple values, often references)

```yaml
parameters:
  affectedZones:
    type: list
    values:
      - [ builtin:management-zones, zone-a, id ]
      - [ builtin:management-zones, zone-b, id ]
```

### Inline JSON (advanced, rare)

`type: json` allows embedding a JSON blob as a single parameter. Use sparingly — at that point the data probably belongs in the `template.json` directly.

---

## 5. The `template.json`

The payload Monaco sends to Dynatrace, with parameter substitution via Go templates. Adapted from the upstream `profile.json`, reformatted to dt-pilot's 2-space JSON indentation:

```json
{
  "name": "{{.name}}",
  "managementZone": "{{.managementZoneId}}",
  "severityRules": [
    { "severityLevel": "PERFORMANCE", "delayInMinutes": 30, "tagFilterIncludeMode": "NONE" }
  ],
  "eventFilters": []
}
```

### Template syntax cheatsheet

| Construct | Meaning |
|---|---|
| `{{ .name }}` | Inject the `name` parameter (the leading dot is mandatory) |
| `{{- .name -}}` | Same, but trim surrounding whitespace (use sparingly; JSON parsers are not whitespace-sensitive) |
| `{{ if .feature }} ... {{ end }}` | Conditional block |
| `{{ range .items }} ... {{ . }} ... {{ end }}` | Iterate (use only when the iterated thing is genuinely a list parameter) |
| `{{ .nested.field }}` | Dotted path through a structured parameter |

### Anti-patterns

- **Inventing parameter names that don't appear in `config.yaml`.** Monaco renders templates during `monaco deploy --dry-run` (and therefore inside `Validate-Monaco.ps1` and `Invoke-MonacoDryRun.ps1`), so an undefined parameter reference surfaces as a render error well before any real deploy. Treat that dry-run error as the first signal — don't bypass it by hand-substituting the value.
- **Hand-templating JSON syntax** (commas, brackets) with Go template control flow. Get a valid JSON shape first, then parameterize. The harder it is to read, the harder it is to review.
- **Embedding tenant URLs or tokens** in `template.json`. They go in `manifest.yaml`'s `environments` block as env-var-backed `url` / `auth` entries.

---

## 6. The deploy lifecycle

Monaco's mutation commands, in the order you'll actually use them:

| Command | What it does |
|---|---|
| `monaco deploy --dry-run manifest.yaml` | Parse manifest + projects, resolve references, render templates, send each request to Dynatrace as a dry-run. Returns the planned create / update / delete list. Does NOT mutate the environment. |
| `monaco deploy manifest.yaml` | Same as above but actually performs the writes. |
| `monaco deploy --environment <env> manifest.yaml` | Restrict to one environment in the manifest. |
| `monaco deploy --group <name> manifest.yaml` | Restrict to one environment group. |
| `monaco deploy --project <name> manifest.yaml` | Restrict to one project. |
| `monaco deploy --continue-on-error manifest.yaml` | Don't stop on first error. Use sparingly — failures often cascade and the second error is meaningless. |
| `monaco delete --manifest manifest.yaml --file deletefile.yaml` | Delete the configs listed in `deletefile.yaml` from the targeted environments. **Requires a deletefile.** Generate with `monaco generate deletefile`. |
| `monaco download --url <url> --token <token> --output-folder downloaded/` | Pull a live environment's configuration into a Monaco-shaped project. |
| `monaco generate deletefile --manifest manifest.yaml` | Produce a deletefile listing everything the manifest references — typically you then prune it to the subset you actually want deleted. |
| `monaco generate schema --schema builtin:<schema-id>` | Dump the JSON schema for a settings 2.0 schema ID, useful for discovering valid fields without guessing. |
| `monaco generate graph --manifest manifest.yaml` | Render the deploy DAG. |
| `monaco account ...` | Subcommands for account-management deploys (`deploy`, `download`, `delete`). Requires `oAuth`. |

### The dt-pilot mandatory sequence

All of the above runs through the wrapper scripts (PR&nbsp;4); the wrappers are not optional. The contract is:

1. **Edit** YAML/JSON.
2. **Validate** (`Validate-Monaco.ps1` — wraps `monaco deploy --dry-run` and exits non-zero on any structural error).
3. **Dry-run** for review (`Invoke-MonacoDryRun.ps1` — same `--dry-run` invocation but persists the rendered output to `dryrun/<env>.json` for human / agent review).
4. **Wait for explicit user approval.**
5. **Deploy** the saved dry-run (`Invoke-MonacoDeploy.ps1 -DryRunFile dryrun/<env>.json`). The wrapper refuses to run without `-DryRunFile`.
6. **Delete** (when needed) requires a curated deletefile **and** a `-Confirm` flag: `Invoke-MonacoDelete.ps1 -DeleteFile deletefile.yaml -Confirm`.

If more than 30 minutes pass between steps 3 and 5, re-dry-run. Live environment drift can invalidate a stale plan.

---

## 7. Renaming, moving, and refactoring

Three principles:

1. **`id` is identity.** Don't rename it. If you must, do it in two PRs: PR A introduces the new ID by `monaco download`-ing the existing config under the new ID; PR B `monaco delete`s the old config with a curated deletefile.
2. **File names are cosmetic.** `git mv` a config file freely; Monaco only cares about the `id` inside.
3. **Moving a config between projects** is the same as renaming: it changes identity. Same two-PR pattern.

For the special case of **bringing a UI-managed environment under Monaco** (the most common refactor), see `agents/chief-systems-engineer.agent.md` — it has the full inventory → download → restructure → validate → dry-run-on-source-env → promote sequence.

---

## 8. Common Dynatrace schemas and their gotchas

| Schema | Notes |
|---|---|
| `builtin:alerting.profile` | `severityRules` is order-sensitive. `eventFilters` is often `[]` for a default-allow profile. |
| `builtin:management-zones` | `rules` mix `DIMENSION` and `ME` (monitored-entity) types — they have different inner shapes. Wrong inner shape passes JSON validation but fails the schema check at dry-run. |
| `builtin:problem.notifications` | Each notification type (`EMAIL`, `SLACK`, `WEBHOOK`, `PAGERDUTY`, `JIRA`, `OPSGENIE`, `XMATTERS`) has a different `type`-specific payload shape. Use `monaco generate schema` to dump the per-type shape rather than guessing. |
| `builtin:slo` | `evaluationType` is `AGGREGATE` or `EVENT_BASED`. The two have different required fields. |
| `builtin:host-group` | Scope must be a specific `HOST_GROUP-<id>`, not `environment`. |
| `auto-tag` (classic API) | Not yet in settings 2.0. Uses `type.api: auto-tag` instead of `type.settings`. |

When in doubt: `Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema <schema-id>` (PR&nbsp;4) — dumps the live schema. Never invent fields.

---

## 9. DQL — the read-side companion

DQL (Dynatrace Query Language) is how you query Grail (Dynatrace's data lakehouse) for logs, metrics, traces, events, problems, and security findings. Monaco doesn't write DQL — DQL is a read tool — but DQL queries often inform what you write next (e.g. "what's the current SLO error budget burn?", "which hosts are in management zone X?"). The Dynatrace MCP server exposes DQL directly to agents.

For a focused DQL primer with concrete examples, see [`docs/DQL-PRIMER.md`](../../docs/DQL-PRIMER.md). The short version:

- Use the Dynatrace MCP server's `generate_dql_from_natural_language` and `verify_dql` tools to compose queries; use `execute_dql` to run them.
- DQL pipelines start with `fetch <bucket>` and chain `filter`, `summarize`, `sort`, `fields`, `limit`.
- Time ranges are passed as a separate parameter to `execute_dql`, not encoded in the query string.

---

## 10. Refusal list (also enforced by `agents/dynatrace.agent.md`)

The agent will refuse to:

- Run a real `monaco deploy` (not `--dry-run`) without a saved dry-run file from `Invoke-MonacoDryRun.ps1`.
- Run `monaco delete` without both a curated deletefile and an explicit `-Confirm` flag.
- Commit secrets to the repository.
- Hand-edit files under `modules/configs/` (regenerate via `Sync-ConfigCatalog.ps1` instead, PR&nbsp;8).
- Push to `main` directly.
- Squash-merge a PR before its Copilot review threads are resolved.

---

## 11. When you need information not in this skill

In priority order:

1. The Dynatrace MCP server (PR&nbsp;5) — `find_entity_by_name`, `execute_dql`, `verify_dql`, `generate_dql_from_natural_language`, `chat_with_davis_copilot`.
2. `monaco generate schema` (wrapped by `Invoke-MonacoGenerate.ps1` in PR&nbsp;4) for live settings 2.0 schemas.
3. [Dynatrace docs](https://docs.dynatrace.com) — particularly `/docs/deliver/configuration-as-code/monaco` for Monaco and `/docs/discover-dynatrace/references/dynatrace-query-language` for DQL.
4. The upstream Monaco repo at `Dynatrace/dynatrace-configuration-as-code` — `test/configuration/` contains authoritative YAML/JSON fixtures.

Never guess Dynatrace API shapes from training data — they change between releases. Verify against the live schema.
