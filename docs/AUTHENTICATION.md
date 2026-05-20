# Authentication

dt-pilot reads credentials exclusively from environment variables. No tokens, OAuth secrets, or tenant URLs live in committed files. This document covers the three supported auth modes, how to provision each, and how to wire them up locally and in CI.

## Auth modes

| Mode | Used by | Required env vars |
|---|---|---|
| **Platform token** | Monaco deploys (settings 2.0), Dynatrace MCP server | `DT_ENVIRONMENT`, `DT_PLATFORM_TOKEN` |
| **OAuth client credentials** | Monaco deploys + account-management ops, Dynatrace MCP server | `DT_ENVIRONMENT`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` |
| **Classic API token** | Classic config-API Monaco deploys (`auto-tag` and similar legacy APIs) | `DT_ENVIRONMENT`, plus a per-environment classic token env var named in `manifest.yaml` |

The Dynatrace MCP server also supports browser SSO (`DT_ENVIRONMENT` only) — fine for interactive use, not appropriate for CI or unattended deploys.

## Picking an auth mode

| Workflow | Recommended auth |
|---|---|
| Local exploration of an existing tenant via DQL / MCP | Platform token (fast, narrow scope) |
| Local-dev Monaco deploys against a sandbox tenant | Platform token |
| CI Monaco deploys (any environment) | OAuth client credentials |
| Account-management deploys (groups, policies, user assignments) | OAuth client credentials — required; nothing else works |
| Production deploys with a separate identity per environment | OAuth client credentials, one client per environment |

## Provisioning a platform token

1. In Dynatrace, **Account menu → Access tokens → Generate new token**.
2. Name it `dt-pilot:<who>:<purpose>` (e.g. `dt-pilot:alice:local-dev`). The name is for auditing — make it specific.
3. Scopes — minimum for settings 2.0 deploys:
   - `settings:objects:read`
   - `settings:objects:write`
   - `settings:schemas:read`
4. Add scopes for any classic APIs your workspace touches (`ReadConfig`, `WriteConfig` for the relevant config-API endpoints).
5. Copy the token immediately (Dynatrace shows it once). Store it in your local env or a secrets manager:

   ```powershell
   # Per-session (lost when the shell closes)
   $env:DT_PLATFORM_TOKEN = "dt0c01.XXXXXXXXXXXXXXXXXXXXXXXX.YYYY..."
   $env:DT_ENVIRONMENT    = "https://abc12345.apps.dynatrace.com"
   ```

   For a persistent local setup, store these in your user profile (`$PROFILE` in PowerShell, `~/.zshrc` / `~/.bashrc` in shells) — **not** in a committed `.env` file.

## Provisioning an OAuth client

OAuth client provisioning is a **production-impacting administrative action**. Do it via the Dynatrace Account Management UI or API and treat the resulting credentials as sensitive as any other production secret.

1. **Account Management → Identity & Access management → OAuth clients → Create OAuth client.**
2. Required scopes for settings 2.0 deploys (minimum):
   - `app-engine:apps:run`
   - `settings:objects:read`
   - `settings:objects:write`
   - `settings:schemas:read`
3. Add **only** the scopes the client actually needs. Never grant `*:*`.
4. For account-management deploys, also add the relevant `iam:*` scopes (depends on what your Monaco account project does).
5. Save the client ID and secret. The secret is shown once.
6. Wire into env vars:

   ```bash
   export DT_ENVIRONMENT="https://abc12345.apps.dynatrace.com"
   export OAUTH_CLIENT_ID="dt0s02.XXXXXXXX"
   export OAUTH_CLIENT_SECRET="dt0s02.XXXXXXXX.YYYY..."
   ```

7. If your tenant uses a non-default SSO, also set:

   ```bash
   export OAUTH_TOKEN_ENDPOINT="https://sso-prod.example.dynatrace.com/sso/oauth2/token"
   ```

   The `manifest.yaml` would then reference this via `auth.oAuth.tokenEndpoint.type: environment, value: OAUTH_TOKEN_ENDPOINT`.

## Wiring auth into `manifest.yaml`

The manifest never holds secrets; it names the env vars Monaco should resolve at deploy time. From the canonical example in [`skills/dynatrace/SKILL.md`](../skills/dynatrace/SKILL.md):

```yaml
environments:
  - name: dev
    url:
      type: environment
      value: DT_ENVIRONMENT_DEV
    auth:
      token:
        name: DT_PLATFORM_TOKEN_DEV
  - name: prod
    url:
      type: environment
      value: DT_ENVIRONMENT_PROD
    auth:
      oAuth:
        clientId:
          name: OAUTH_CLIENT_ID_PROD
        clientSecret:
          name: OAUTH_CLIENT_SECRET_PROD
```

Note: the per-environment suffix (`_DEV`, `_PROD`) is the convention. It keeps `dev` and `prod` secrets distinct in `$env:` and in CI secret stores, and it makes "which environment is this token for?" trivially answerable from the variable name.

## CI configuration

### GitHub Actions

Store secrets at the repository or organization level via **Settings → Secrets and variables → Actions**. Reference them in workflows by name:

```yaml
jobs:
  validate:
    runs-on: ubuntu-latest
    env:
      DT_ENVIRONMENT:        ${{ vars.DT_ENVIRONMENT_DEV }}
      OAUTH_CLIENT_ID:       ${{ secrets.OAUTH_CLIENT_ID_DEV }}
      OAUTH_CLIENT_SECRET:   ${{ secrets.OAUTH_CLIENT_SECRET_DEV }}
    steps:
      - uses: actions/checkout@v4
      - name: Monaco dry-run
        shell: pwsh
        run: ./scripts/Validate-Monaco.ps1 -Path .
```

Production secrets belong in a separate **environment** (in the GitHub Actions sense) that requires reviewer approval before the workflow can read them. See `agents/chief-systems-engineer.agent.md` for the multi-environment strategy.

### Other CI systems

The same shape applies: store secrets in the CI's secret manager, reference by env var, never echo them. The Monaco wrappers and `Start-DynatraceMcpServer.ps1` never log credential values.

## Rotation

| Credential | Rotation cadence | Mechanism |
|---|---|---|
| Platform token | 30–90 days | Generate new token in UI → update env var / CI secret → delete old token |
| OAuth client secret | Per org rotation policy (90–180 days typical) | Rotate via Account Management → update CI secret → delete old secret |
| Classic API token | 30–90 days | Same as platform token |

Rotation should always be a `chore/rotate-<env>-<credential>` PR that updates only the **secret name** (or version) — never a commit that contains a value.

## What to do if a secret leaks

1. **Rotate immediately.** Generate a new token / OAuth secret in Dynatrace; delete the old one.
2. **Update CI secrets** to the new value.
3. **Update local developer env vars** for affected developers.
4. **Audit access logs** in Dynatrace for use of the leaked credential.
5. **Notify** the security team per your org's incident process.
6. **Post-mortem** the leak — typically the failure was a missing `.gitignore` entry, a misconfigured `.vscode/mcp.json`, or a hand-edited workflow file. Fix the upstream cause so it doesn't recur.

## Auth check command

```powershell
./scripts/Test-DynatraceMcpReadiness.ps1
```

Validates env vars, Node.js version, and the MCP catalog before you try to run the MCP server or any deploy. Run this first when something isn't working — it gives one targeted error per issue.
