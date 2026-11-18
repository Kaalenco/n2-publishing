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
`--skip-duplicate`. A nuget.org version cannot be deleted, only unlisted.

## Authentication

- nuget.org: Trusted Publishing. The `push` job exchanges its GitHub OIDC token for a
  short-lived nuget.org key (`NuGet/login`). No API key is stored. The nuget.org policy
  `n2-package-publishing` (owner `gjkaal`) names repository `Kaalenco/n2-publishing`, workflow
  file `publish.yml` and environment `production`.
- vault-packages: repository secret `NUGET_PAT`, a read-only Azure DevOps PAT with scope
  Packaging (Read). Only the `plan` job sees it.

## Local tests

```powershell
Invoke-Pester -Path tests
```

## Adding a package

Add its id to `packages` in `promotion.json`, in dependency order. Only `N2.*` ids are
accepted (the script refuses anything else, matching the nuget.org scope). The nuget.org owner of the
package must be `gjkaal` (the trusted publishing policy covers packages owned by that user).
