<#
.SYNOPSIS
Gathers the artifacts of a CI run into the release files, with build-keys.json.

.DESCRIPTION
    ./scripts/Merge-ReleaseArtifacts.ps1 -ArtifactsPath artifacts -KeysPath build-keys/build-keys.json -OutputPath binaries

-ArtifactsPath has one folder per artifact, as actions/download-artifact writes
them without merge-multiple. Their files are copied to -OutputPath; two
artifacts with a file of the same name fail the script.

-KeysPath is the key of every unit, from scripts/Get-BuildPlan.ps1. They are
written to -OutputPath/build-keys.json, with the files of each build unit (the
files of the artifact of the same name), for the next run to reuse:

    { "version": 1, "units": { "<unit>": { "key": "<sha256>", "files": [ ... ] } } }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsPath,

    [Parameter(Mandatory = $true)]
    [string]$KeysPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$artifactFiles = @{}
foreach ($directory in Get-ChildItem -LiteralPath $ArtifactsPath -Directory | Sort-Object Name) {
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File -Recurse | Sort-Object Name) {
        $destination = Join-Path $OutputPath $file.Name
        if (Test-Path -LiteralPath $destination) {
            throw "$($file.Name) is in more than one artifact (found again in $($directory.Name))"
        }

        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $names.Add($file.Name)
    }

    $artifactFiles[$directory.Name] = $names
}

$keys = Get-Content -LiteralPath $KeysPath -Raw | ConvertFrom-Json
$units = [ordered]@{}
foreach ($property in $keys.units.PSObject.Properties) {
    $unit = [ordered]@{ key = $property.Value.key }
    if ($property.Value.kind -eq "build") {
        $files = $artifactFiles[$property.Name]
        if (-not $files -or $files.Count -eq 0) {
            throw "No artifact '$($property.Name)': the units of scripts/Get-BuildPlan.ps1 must match the artifacts of ci.yml"
        }
        $unit.files = @($files)
    }
    $units[$property.Name] = $unit
}

$buildKeys = [ordered]@{ version = 1; units = $units }
ConvertTo-Json $buildKeys -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath "build-keys.json") -Encoding utf8NoBOM
Write-Host "Copied $(@($artifactFiles.Values | ForEach-Object { $_ }).Count) files from $($artifactFiles.Count) artifacts; recorded $($units.Count) build keys"
