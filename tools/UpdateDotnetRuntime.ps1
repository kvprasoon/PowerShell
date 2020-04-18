# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param (
)

<#
 .DESCRIPTION Update the global.json with the new SDK version to be used.
#>
function Update-GlobalJson([string] $Version) {
    $psGlobalJsonPath = Resolve-Path "$PSScriptRoot/../global.json"
    $psGlobalJson = Get-Content -Path $psGlobalJsonPath -Raw | ConvertFrom-Json
    $psGlobalJson.sdk.version = $Version
    $psGlobalJson | ConvertTo-Json | Out-File -FilePath $psGlobalJsonPath -Force
}

<#
 .DESCRIPTION Iterate through all the csproj to find all the packages that need to be updated
#>
function Update-PackageVersion {

    class PkgVer {
        [string] $Name
        [string] $Version
        [string] $NewVersion
        [string] $Path

        PkgVer($n, $v, $nv, $p) {
            $this.Name = $n
            $this.Version = $v
            $this.NewVersion = $nv
            $this.Path = $p
        }
    }

    $skipModules = @(
        "NJsonSchema"
        "Markdig.Signed"
        "PowerShellHelpFiles"
        "Newtonsoft.Json"
        "Microsoft.ApplicationInsights"
        "Microsoft.Management.Infrastructure"
        "Microsoft.PowerShell.Native"
        "Microsoft.NETCore.Windows.ApiSets"
    )

    $packages = [System.Collections.Generic.Dictionary[[string], [PkgVer]]]::new()

    Get-ChildItem -Path "$PSScriptRoot/../src/" -Recurse -Filter "*.csproj" -Exclude 'PSGalleryModules.csproj' | ForEach-Object {
        $prj = [xml] (Get-Content $_.FullName -Raw)
        $pkgRef = $prj.Project.ItemGroup.PackageReference

        foreach ($p in $pkgRef) {
            if ($null -ne $p -and -not $skipModules.Contains($p.Include)) {
                if (-not $packages.ContainsKey($p.Include)) {
                    $packages.Add($p.Include, [PkgVer]::new($p.Include, $p.Version, $null, $_.FullName))
                }
            }
        }
    }

    $versionPattern = (Get-Content "$PSScriptRoot/../DotnetRuntimeMetadata.json" | ConvertFrom-Json).sdk.packageVersionPattern

    $packages.GetEnumerator() | ForEach-Object {
        $pkgs = Find-Package -Name $_.Key -AllVersions -AllowPreReleaseVersions -Source 'dotnet5'

        $version = $_.Value.Version

        foreach ($p in $pkgs) {
            if ($p.Version -like "$versionPattern*") {
                if ([System.Management.Automation.SemanticVersion] ($version) -lt [System.Management.Automation.SemanticVersion] ($p.Version)) {
                    $_.Value.NewVersion = $p.Version
                    break
                }
            }
        }
    }

    $pkgsByPath = $packages.Values | Group-Object -Property Path

    $pkgsByPath | ForEach-Object {
        Update-CsprojFile -Path $_.Name -Values $_.Group
    }
}

<#
 .DESCRIPTION Update package versions to the latest as per the pattern mentioned in DotnetRuntimeMetadata.json
#>
function Update-CsprojFile([string] $path, $values) {
    $fileContent = Get-Content $path -raw
    $updated = $false

    foreach ($v in $values) {
        if ($v.NewVersion) {
            $stringToReplace = "<PackageReference Include=`"$($v.Name)`" Version=`"$($v.Version)`" />"
            $newString = "<PackageReference Include=`"$($v.Name)`" Version=`"$($v.NewVersion)`" />"

            $fileContent = $fileContent -replace $stringToReplace, $newString
            $updated = $true
        }
    }

    if ($updated) {
        $fileContent | Out-File -FilePath $path -Force
    }
}

$dotnetMetadataPath = "$PSScriptRoot/../DotnetRuntimeMetadata.json"
$dotnetMetadataJson = Get-Content $dotnetMetadataPath -Raw | ConvertFrom-Json

# Channel is like: $Channel = "5.0.1xx-preview2"
$Channel = $dotnetMetadataJson.sdk.channel

Import-Module "$PSScriptRoot/../build.psm1" -Force

Find-Dotnet

if(-not (Get-PackageSource -Name 'dotnet5' -ErrorAction SilentlyContinue))
{
    $nugetFeed = ([xml](Get-Content .\nuget.config -Raw)).Configuration.packagesources.add | Where-Object { $_.Key -eq 'dotnet5' } | Select-Object -ExpandProperty Value
    Register-PackageSource -Name 'dotnet5' -Location $nugetFeed -ProviderName NuGet
    Write-Verbose -Message "Register new package source 'dotnet5'" -verbose
}

## Install latest version from the channel

Install-Dotnet -Channel "$Channel" -Version 'latest'

Write-Verbose -Message "Installing .NET SDK completed." -Verbose

$latestSdkVersion = (dotnet --list-sdks | Select-Object -Last 1 ).Split() | Select-Object -First 1

Write-Verbose -Message "Installing .NET SDK completed, version - $latestSdkVersion" -Verbose

Update-GlobalJson -Version $latestSdkVersion

Write-Verbose -Message "Updating global.json completed." -Verbose

Update-PackageVersion

Write-Verbose -Message "Updating project files completed." -Verbose
