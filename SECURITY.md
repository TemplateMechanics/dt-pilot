# Security Policy

## Supported versions

dt-pilot is a development harness, not a runtime service. Security fixes are
applied to the `main` branch only. There is no LTS or backport policy.

## Reporting a vulnerability

If you believe you have found a security vulnerability in dt-pilot — for
example, a wrapper script that exfiltrates credentials, a schema check that
fails open, or an MCP configuration that leaks secrets — please report it
privately:

1. **Do not** open a public GitHub issue.
2. Email the maintainers via the contact address listed on the
   [TemplateMechanics GitHub organization profile](https://github.com/TemplateMechanics).
3. Include reproduction steps, affected versions, and any suggested mitigation.

We will acknowledge receipt within 5 business days and aim to provide a
remediation plan or fix within 30 days for confirmed issues.

## What's in scope

- The PowerShell wrapper scripts under `scripts/`
- The committed MCP configuration under `.vscode/mcp.json` and the catalog
- CI workflows under `.github/workflows/`
- The example projects under `examples/`

## What's out of scope

- Vulnerabilities in upstream Monaco, the Dynatrace platform, or the Dynatrace
  MCP server itself — please report those to the respective project.
- Misuse of the harness by a user who has already chosen to bypass the safety
  rails (e.g. running `monaco deploy` directly without the wrapper).

## Credential handling expectations

dt-pilot **never** reads, prints, or persists Dynatrace credentials. Tokens are
read from environment variables (`DT_PLATFORM_TOKEN`, `OAUTH_CLIENT_ID`,
`OAUTH_CLIENT_SECRET`) and passed straight through to Monaco / the MCP server.
If you see a wrapper that violates this, treat it as a security bug.

The pre-commit gate scans MCP configuration files for hardcoded secrets. If
you find a way around that check, please report it.
