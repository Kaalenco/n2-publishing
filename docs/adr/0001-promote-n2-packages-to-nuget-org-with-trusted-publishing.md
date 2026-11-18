# 0001 - Promote N2 packages to nuget.org with Trusted Publishing

## Status

Accepted, 2026-11-18 (user decision).

## Context

N2.* packages are built and published to the private Azure Artifacts feed `vault-packages`.
nuget.org no longer lets this account create API keys, so a classic `dotnet nuget push` with a
key is not possible. n2-core, n2-abstractions and n2-identity are hosted on Azure DevOps only,
so no single GitHub repository with a package build can publish all of them.

## Decision

- A GitHub Actions workflow (`publish.yml`) in this dedicated repository (public) publishes to
  nuget.org with Trusted Publishing: policy `n2-package-publishing`, workflow `publish.yml`,
  environment `production`, with a required reviewer and restricted to deployments from `trunk`.
- Schedule: monthly, on the 1st.
- Eligibility: release versions only (no prerelease), at least 7 days on the vault, and newer
  than the latest release on nuget.org.
- The exact `.nupkg` from the vault is pushed unchanged (no rebuild). The SHA-256 recorded in
  the plan job and the nuspec id/version are re-checked in the push job.
- A manual run may pass an explicit `Id=Version` list. It skips only the age rule.
- Manual runs are a dry run by default.
- Only `N2.*` ids are accepted.
- The vault is read through a read-only Packaging PAT (secret `NUGET_PAT`), available to the
  plan job only. The OIDC token (`id-token: write`) is available to the push job only.

## Consequences

- A version on nuget.org cannot be deleted, only unlisted. A wrong push is permanent.
- The repository was made public (2026-11-18) to get GitHub's environment and branch
  protections on the free plan. Nothing secret is in the repository, and the feed URL is already
  public elsewhere.
- The gate: environment `production` requires a reviewer (the repository owner) and accepts
  deployments from `trunk` only, so the monthly run waits for approval. Branch protection on
  `trunk` forbids force pushes and deletion.
- The Trusted Publishing policy is scoped to the owner, not to an id pattern. The `N2.*` filter
  in the scripts and in the workflow is the id restriction.
- Packages must be owned by the policy's nuget.org user.
- The vault PAT is a long-lived secret, but read-only and limited to the plan job.

## Alternatives considered

- An Azure Pipeline with an API key: no keys can be created, and it would need a long-lived
  secret.
- A local push with an API key: same key problem, and no audit trail or fixed eligibility rules.
- Hosting the workflow in n2-logging or n2-core-entity: those repositories do not own the other
  packages, and the policy and the secrets would be mixed with unrelated build workflows.
