#requires -Version 7.0
<#
.SYNOPSIS
    Decides which N2 package versions go from vault-packages to nuget.org and downloads them.

.DESCRIPTION
    Without -ExplicitPackages: for every package in promotion.json, the latest vault version that
    is a release, at least minAgeDays old on the vault and newer than nuget.org.
    With -ExplicitPackages 'Id=Version,...': exactly those versions; the age rule is skipped,
    the release and newer-than-nuget.org rules still apply. A refused entry fails the run.

    Writes <OutDir>/plan.json (ordered list: Id, Version, File, Sha256) and the .nupkg files.
    The vault PAT is read from the environment variable VAULT_PAT (read-only Packaging PAT).
    On GitHub it sets the step output 'count' and writes a job summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutDir,
    [string] $ExplicitPackages = '',
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'promotion.json'),
    [datetime] $Now = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Promotion.psm1') -Force

if (-not $env:VAULT_PAT) { throw 'VAULT_PAT is not set (read-only Packaging PAT for vault-packages).' }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$headers = New-VaultHeaders $env:VAULT_PAT
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$outside = @($config.packages | Where-Object { -not (Test-AllowedPackageId $_) })
if ($outside.Count -gt 0) { throw "promotion.json lists packages outside N2.*: $($outside -join ', ')." }
$explicit = @(ConvertFrom-PackageList $ExplicitPackages)
$requests = if ($explicit.Count -gt 0) { $explicit } else {
    @($config.packages | ForEach-Object { [pscustomobject]@{ Id = $_; Version = $null } })
}

$plan = @()
$report = @()
foreach ($request in $requests) {
    $vaultVersions = @(Get-VaultVersions -Vault $config.vault -Id $request.Id -Headers $headers)
    $nugetVersions = @(Get-NuGetOrgVersions -Id $request.Id)

    if ($request.Version) {
        $reason = Test-ExplicitVersion -Version $request.Version -VaultVersions $vaultVersions -NuGetOrgVersions $nugetVersions
        if ($reason) { throw "$($request.Id) $($request.Version) refused: $reason." }
        $version = $request.Version
    }
    else {
        $version = Select-EligibleVersion -VaultVersions $vaultVersions -NuGetOrgVersions $nugetVersions -Now $Now -MinAgeDays $config.minAgeDays
    }

    $nugetMax = Get-MaxReleaseVersion $nugetVersions
    if (-not $version) {
        $report += "| $($request.Id) | - | $nugetMax | skipped: no eligible version |"
        Write-Host "skip  $($request.Id) (no eligible version; nuget.org $nugetMax)"
        continue
    }
    $plan += [pscustomobject]@{ Id = $request.Id; Version = $version }
    $report += "| $($request.Id) | $version | $nugetMax | promote |"
    Write-Host "plan  $($request.Id) $version (nuget.org $nugetMax)"
}

if ($plan.Count -gt 0) {
    $baseAddress = Get-VaultBaseAddress -Vault $config.vault -Headers $headers
    foreach ($item in $plan) {
        $file = Save-VaultPackage -BaseAddress $baseAddress -Headers $headers -Id $item.Id -Version $item.Version -OutDir $OutDir
        $item | Add-Member File (Split-Path $file -Leaf)
        $item | Add-Member Sha256 (Get-FileHash $file -Algorithm SHA256).Hash
    }
}
ConvertTo-Json -InputObject @($plan) -Depth 3 | Set-Content (Join-Path $OutDir 'plan.json') -Encoding utf8NoBOM

if ($env:GITHUB_OUTPUT) { "count=$($plan.Count)" | Add-Content $env:GITHUB_OUTPUT }
if ($env:GITHUB_STEP_SUMMARY) {
    $mode = if ($explicit.Count -gt 0) { 'explicit list (age rule skipped)' } else { "package list (min age $($config.minAgeDays) days)" }
    @("### Promotion plan: $mode", '', '| Package | Vault version | nuget.org latest | Action |', '| --- | --- | --- | --- |') + $report |
        Add-Content $env:GITHUB_STEP_SUMMARY
    if ($plan.Count -gt 0) {
        @('', '| File | SHA-256 |', '| --- | --- |') + @($plan | ForEach-Object { "| $($_.File) | $($_.Sha256) |" }) |
            Add-Content $env:GITHUB_STEP_SUMMARY
    }
}
exit 0
