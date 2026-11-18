#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'Promotion.psm1') -Force
    $script:Now = [datetime]::new(2026, 12, 1, 6, 0, 0, [DateTimeKind]::Utc)
    function New-VaultVersion([string] $Version, [int] $DaysOld, [bool] $Deleted = $false) {
        [pscustomobject]@{ Version = $Version; PublishDate = $script:Now.AddDays(-$DaysOld); IsDeleted = $Deleted }
    }
}

Describe 'ConvertTo-ReleaseVersion' {
    It 'parses a release version' { ConvertTo-ReleaseVersion '2.0.1' | Should -Be ([version] '2.0.1') }
    It 'ignores build metadata' { ConvertTo-ReleaseVersion '2.0.1+abc' | Should -Be ([version] '2.0.1') }
    It 'rejects a prerelease' { ConvertTo-ReleaseVersion '2.1.0-beta.1' | Should -BeNullOrEmpty }
    It 'rejects garbage' { ConvertTo-ReleaseVersion 'abc' | Should -BeNullOrEmpty }
}

Describe 'Select-EligibleVersion (scheduled rules)' {
    It 'promotes a release that is old enough and newer than nuget.org' {
        $vault = @(New-VaultVersion '2.0.0' 10)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -Be '2.0.0'
    }
    It 'skips a version younger than the minimum age' {
        $vault = @(New-VaultVersion '2.0.0' 6)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -BeNullOrEmpty
    }
    It 'accepts exactly the minimum age' {
        $vault = @(New-VaultVersion '2.0.0' 7)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @() -Now $Now -MinAgeDays 7 | Should -Be '2.0.0'
    }
    It 'skips a prerelease even when old' {
        $vault = @(New-VaultVersion '2.0.0-rc.1' 30)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -BeNullOrEmpty
    }
    It 'skips a version not newer than nuget.org' {
        $vault = @(New-VaultVersion '1.7.0' 30)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -BeNullOrEmpty
    }
    It 'falls back to an older eligible version when the newest is too young' {
        $vault = @((New-VaultVersion '2.0.0' 20), (New-VaultVersion '2.0.1' 2))
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -Be '2.0.0'
    }
    It 'ignores deleted vault versions' {
        $vault = @(New-VaultVersion '2.0.0' 20 $true)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0') -Now $Now -MinAgeDays 7 | Should -BeNullOrEmpty
    }
    It 'compares numerically, not as text' {
        $vault = @(New-VaultVersion '1.10.0' 20)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.9.0') -Now $Now -MinAgeDays 7 | Should -Be '1.10.0'
    }
    It 'ignores nuget.org prereleases when comparing' {
        $vault = @(New-VaultVersion '2.0.0' 20)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @('1.7.0', '3.0.0-alpha') -Now $Now -MinAgeDays 7 | Should -Be '2.0.0'
    }
    It 'promotes a package that is not on nuget.org yet' {
        $vault = @(New-VaultVersion '2.0.0' 20)
        Select-EligibleVersion -VaultVersions $vault -NuGetOrgVersions @() -Now $Now -MinAgeDays 7 | Should -Be '2.0.0'
    }
    It 'returns nothing for an empty vault' {
        Select-EligibleVersion -VaultVersions @() -NuGetOrgVersions @() -Now $Now -MinAgeDays 7 | Should -BeNullOrEmpty
    }
}

Describe 'Test-ExplicitVersion (manual rules, age skipped)' {
    It 'allows a fresh release newer than nuget.org' {
        Test-ExplicitVersion -Version '2.0.1' -VaultVersions @(New-VaultVersion '2.0.1' 0) -NuGetOrgVersions @('1.7.3') | Should -BeNullOrEmpty
    }
    It 'refuses a prerelease' {
        Test-ExplicitVersion -Version '2.0.1-rc' -VaultVersions @(New-VaultVersion '2.0.1-rc' 0) -NuGetOrgVersions @() | Should -Be 'not a release version'
    }
    It 'refuses a version missing on the vault' {
        Test-ExplicitVersion -Version '2.0.2' -VaultVersions @(New-VaultVersion '2.0.1' 0) -NuGetOrgVersions @() | Should -Be 'not on vault-packages'
    }
    It 'refuses a version not newer than nuget.org' {
        Test-ExplicitVersion -Version '2.0.0' -VaultVersions @(New-VaultVersion '2.0.0' 0) -NuGetOrgVersions @('2.0.0') | Should -Match 'not newer'
    }
}

Describe 'ConvertFrom-PackageList' {
    It 'parses comma and space separated entries in order' {
        $list = ConvertFrom-PackageList 'N2.Core.Abstractions=2.0.0, N2.Core=2.0.0'
        $list.Count | Should -Be 2
        $list[0].Id | Should -Be 'N2.Core.Abstractions'
        $list[1].Version | Should -Be '2.0.0'
    }
    It 'returns nothing for an empty string' { @(ConvertFrom-PackageList '').Count | Should -Be 0 }
    It 'rejects an entry without a version' { { ConvertFrom-PackageList 'N2.Core' } | Should -Throw }
    It 'rejects shell metacharacters' { { ConvertFrom-PackageList 'N2.Core=2.0.0;rm' } | Should -Throw }
    It 'rejects a package outside N2.*' { { ConvertFrom-PackageList 'Newtonsoft.Json=13.0.3' } | Should -Throw }
}

Describe 'Test-AllowedPackageId' {
    It 'allows N2.*' { Test-AllowedPackageId 'N2.Core.Identity' | Should -BeTrue }
    It 'refuses other ids' { Test-AllowedPackageId 'N2Core' | Should -BeFalse }
}
