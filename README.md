# n2-publishing

Promotes N2 packages from the private Azure Artifacts feed `vault-packages` to nuget.org.
Nothing is rebuilt: the exact `.nupkg` from the vault is pushed unchanged.

## How it runs

Workflow `.github/workflows/publish.yml`:

- **Scheduled** on the 1st of every month (06:00 UTC). For every package in `promotion.json`
  it promotes the latest vault version that is:
  - a release version (no prerelease suffix);
  - published on the vault at least `minAgeDays` (7) days before the run;
  - newer than the latest release version on nuget.org.
  A package without an eligible version is skipped and shown in the job summary.
- **Manual** (*Run workflow*): `dry_run` is on by default (plan + download, no push). The
  optional `packages` input takes an explicit list, e.g.
  `N2.Core.Abstractions=2.0.0,N2.Core=2.0.0`. The age rule is skipped for an explicit list; the
  release and newer-than-nuget.org rules still apply, and a refused entry fails the run.
  Packages are pushed in the order given (put dependencies first).

The `plan` job runs the Pester tests for the rules, decides, downloads and records the SHA-256
of each file. The `push` job (environment `production`) re-checks the hashes and pushes with
`--skip-duplicate`, after refusing non-`N2.*` ids and checking that the nuspec inside each
package matches the plan. A nuget.org version cannot be deleted, only unlisted.

Design decision: [ADR 0001](docs/adr/0001-promote-n2-packages-to-nuget-org-with-trusted-publishing.md).

## Authentication

- nuget.org: Trusted Publishing. The `push` job exchanges its GitHub OIDC token for a
  short-lived nuget.org key (`NuGet/login`). No API key is stored. The nuget.org user is set in
  the workflow (`publish.yml`, step `NuGet/login`), not in `promotion.json`. The nuget.org
  policy `n2-package-publishing` (owner `gjkaal`) names repository `Kaalenco/n2-publishing`,
  workflow file `publish.yml` and environment `production`. The policy is scoped to the owner,
  not to an id pattern: the `N2.*` check in the scripts and in the workflow is the id
  restriction.
- The repository is public (nothing secret in it). Environment `production` (set on 2026-11-18)
  requires a reviewer (the repository owner) and accepts deployments from `trunk` only, so the
  monthly run waits for approval before the `push` job starts. Branch protection on `trunk`
  forbids force pushes and deletion.
- vault-packages: repository secret `NUGET_PAT`, a read-only Azure DevOps PAT with scope
  Packaging (Read). Only the `plan` job sees it.

## Local tests

```powershell
Invoke-Pester -Path tests
```

## Adding a package

Add its id to `packages` in `promotion.json`, in dependency order. Only `N2.*` ids are
accepted (the script refuses anything else; the policy itself is not id-scoped). The nuget.org owner of the
package must be `gjkaal` (the trusted publishing policy covers packages owned by that user).
