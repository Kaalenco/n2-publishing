#requires -Version 7.0
# Eligibility rules and feed access for promoting N2 packages from vault-packages to nuget.org.
# The rule functions are pure (no I/O) and covered by tests/Promotion.Tests.ps1.

Set-StrictMode -Version Latest

$NuGetOrgFlatContainer = 'https://api.nuget.org/v3-flatcontainer'

# Returns a [version] for a release version (no prerelease suffix), otherwise $null.
# Build metadata (+...) is ignored.
function ConvertTo-ReleaseVersion {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Version)
    $core = $Version.Split('+', 2)[0]
    if ($core -match '-') { return $null }
    $parsed = $null
    if ([version]::TryParse($core, [ref] $parsed)) {
        # Missing Build/Revision count as 0, so 2.0.0.0 equals 2.0.0.
        return [version]::new($parsed.Major, $parsed.Minor, [Math]::Max($parsed.Build, 0), [Math]::Max($parsed.Revision, 0))
    }
    return $null
}

# Highest release version in a list of version strings, returned as the original string
# (for messages and summaries), or $null. Compare it via ConvertTo-ReleaseVersion.
function Get-MaxReleaseVersion {
    param([string[]] $Versions)
    $releases = @($Versions | Where-Object { $_ -and (ConvertTo-ReleaseVersion $_) })
    if ($releases.Count -eq 0) { return $null }
    return ($releases | Sort-Object { ConvertTo-ReleaseVersion $_ } -Descending | Select-Object -First 1)
}

# Scheduled rule. VaultVersions: objects with Version (string), PublishDate (datetime), IsDeleted (bool), IsListed (bool).
# Returns the vault version string to promote, or $null:
#   - release version (no prerelease suffix), not deleted, listed;
#   - published on the vault at least MinAgeDays before Now;
#   - newer than the highest release version on nuget.org.
function Select-EligibleVersion {
    param(
        [object[]] $VaultVersions,
        [string[]] $NuGetOrgVersions,
        [Parameter(Mandatory)][datetime] $Now,
        [Parameter(Mandatory)][int] $MinAgeDays
    )
    $cutoff = $Now.ToUniversalTime().AddDays(-$MinAgeDays)
    $candidates = @($VaultVersions | Where-Object {
            -not $_.IsDeleted -and $_.IsListed -and
            (ConvertTo-ReleaseVersion $_.Version) -and
            ([datetime] $_.PublishDate).ToUniversalTime() -le $cutoff
        })
    if ($candidates.Count -eq 0) { return $null }

    $best = $candidates | Sort-Object { ConvertTo-ReleaseVersion $_.Version } -Descending | Select-Object -First 1
    $nugetMax = Get-MaxReleaseVersion $NuGetOrgVersions
    if ($nugetMax -and (ConvertTo-ReleaseVersion $best.Version) -le (ConvertTo-ReleaseVersion $nugetMax)) { return $null }
    return $best.Version
}

# Manual rule (explicit Id=Version): the age rule is skipped, the others apply.
# Returns $null when allowed, otherwise the reason it is refused.
function Test-ExplicitVersion {
    param(
        [Parameter(Mandatory)][string] $Version,
        [object[]] $VaultVersions,
        [string[]] $NuGetOrgVersions
    )
    $release = ConvertTo-ReleaseVersion $Version
    if (-not $release) { return 'not a release version' }
    $matching = @($VaultVersions | Where-Object {
            -not $_.IsDeleted -and (ConvertTo-ReleaseVersion $_.Version) -eq $release
        })
    if ($matching.Count -eq 0) { return 'not on vault-packages' }
    if (@($matching | Where-Object { $_.IsListed }).Count -eq 0) { return 'unlisted on vault-packages' }
    $nugetMax = Get-MaxReleaseVersion $NuGetOrgVersions
    if ($nugetMax -and $release -le (ConvertTo-ReleaseVersion $nugetMax)) { return "not newer than nuget.org $nugetMax" }
    return $null
}

# Only N2.* packages may be promoted. The nuget.org trusted publishing policy is scoped to the
# owner, not to an id pattern, so this check (and the same check in publish.yml) is the id restriction.
function Test-AllowedPackageId {
    param([Parameter(Mandatory)][string] $Id)
    return $Id -like 'N2.*'
}

# Parses 'Id=Version, Id=Version' into objects; throws on a malformed or non-N2 entry.
function ConvertFrom-PackageList {
    param([AllowEmptyString()][string] $Text)
    $result = @()
    foreach ($entry in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        $id, $version = $entry.Split('=', 2)
        if (-not $version -or $id -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$') {
            throw "Malformed package entry '$entry'; expected Id=Version."
        }
        if (-not (Test-AllowedPackageId $id)) { throw "Package '$id' is outside the allowed pattern N2.*." }
        $result += [pscustomobject]@{ Id = $id; Version = $version }
    }
    return $result
}

function New-VaultHeaders {
    param([Parameter(Mandatory)][string] $Pat)
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $basic" }
}

# Versions of one package on the vault feed (Azure DevOps Packaging API).
function Get-VaultVersions {
    param(
        [Parameter(Mandatory)] $Vault,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][hashtable] $Headers
    )
    $query = [uri]::EscapeDataString($Id)
    $uri = "https://feeds.dev.azure.com/$($Vault.organization)/$($Vault.project)/_apis/packaging/Feeds/$($Vault.feed)/packages" +
        "?protocolType=NuGet&packageNameQuery=$query&includeAllVersions=true&includeDeleted=true&api-version=7.1"
    $response = Invoke-RestMethod -Uri $uri -Headers $Headers
    $package = $response.value | Where-Object { $_.name -ieq $Id } | Select-Object -First 1
    if (-not $package) { return @() }
    return @($package.versions | ForEach-Object {
            [pscustomobject]@{
                Version     = if ($_.PSObject.Properties['normalizedVersion'] -and $_.normalizedVersion) { $_.normalizedVersion } else { $_.version }
                PublishDate = [datetime] $_.publishDate
                IsDeleted   = [bool] ($_.PSObject.Properties['isDeleted'] -and $_.isDeleted)
                IsListed    = -not ($_.PSObject.Properties['isListed'] -and $_.isListed -eq $false)
            }
        })
}

# All versions on nuget.org (listed and unlisted); empty when the package does not exist.
function Get-NuGetOrgVersions {
    param([Parameter(Mandatory)][string] $Id)
    try {
        return @((Invoke-RestMethod -Uri "$NuGetOrgFlatContainer/$($Id.ToLowerInvariant())/index.json").versions)
    }
    catch {
        $property = $_.Exception.PSObject.Properties['Response']
        if ($property -and $property.Value -and [int] $property.Value.StatusCode -eq 404) { return @() }
        throw
    }
}

function Get-VaultBaseAddress {
    param([Parameter(Mandatory)] $Vault, [Parameter(Mandatory)][hashtable] $Headers)
    $index = "https://pkgs.dev.azure.com/$($Vault.organization)/$($Vault.project)/_packaging/$($Vault.feed)/nuget/v3/index.json"
    $resource = (Invoke-RestMethod -Uri $index -Headers $Headers).resources |
        Where-Object { $_.'@type' -like 'PackageBaseAddress/3.0.0*' } | Select-Object -First 1
    if (-not $resource) { throw 'vault-packages service index has no PackageBaseAddress resource.' }
    return $resource.'@id'.TrimEnd('/')
}

# Downloads the exact .nupkg and checks the nuspec id/version. Returns the file path.
function Save-VaultPackage {
    param(
        [Parameter(Mandatory)][string] $BaseAddress,
        [Parameter(Mandatory)][hashtable] $Headers,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $OutDir
    )
    $lowerId = $Id.ToLowerInvariant()
    $lowerVersion = $Version.ToLowerInvariant()
    $file = Join-Path $OutDir "$lowerId.$lowerVersion.nupkg"
    Invoke-WebRequest -Uri "$BaseAddress/$lowerId/$lowerVersion/$lowerId.$lowerVersion.nupkg" -Headers $Headers -OutFile $file | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($file)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -notlike '*/*' -and $_.Name -like '*.nuspec' } | Select-Object -First 1
        if (-not $entry) { throw "No nuspec in $file." }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try { [xml] $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
    $nuspecVersion = ConvertTo-ReleaseVersion ([string] $nuspec.package.metadata.version)
    if ($nuspec.package.metadata.id -ne $Id -or -not $nuspecVersion -or $nuspecVersion -ne (ConvertTo-ReleaseVersion $Version)) {
        throw "Downloaded $($nuspec.package.metadata.id) $($nuspec.package.metadata.version), expected $Id $Version."
    }
    return $file
}

Export-ModuleMember -Function ConvertTo-ReleaseVersion, Get-MaxReleaseVersion, Select-EligibleVersion, Test-AllowedPackageId,
    Test-ExplicitVersion, ConvertFrom-PackageList, New-VaultHeaders, Get-VaultVersions,
    Get-NuGetOrgVersions, Get-VaultBaseAddress, Save-VaultPackage
