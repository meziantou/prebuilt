<#
.SYNOPSIS
Downloads the files of a build unit from a release, instead of building them.

.DESCRIPTION
    ./scripts/Get-ReleaseFiles.ps1 -Tag <release> -Artifact <unit>

Used by a CI job that scripts/Get-BuildPlan.ps1 marked as reused: the files the
release recorded for the unit in build-keys.json are written to the current
directory, for the job to upload as its artifact, as if it had built them.
Each file is checked against the size and SHA-256 of prebuilt-tools.json.

Any failure is fatal: the job runs on ubuntu-latest once reused, so it cannot
build the files instead. Running the workflow again, or with the rebuild input,
recovers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [Parameter(Mandatory = $true)]
    [string]$Artifact,

    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
if ($env:GH_TOKEN) {
    $headers.Authorization = "Bearer $env:GH_TOKEN"
}

function Invoke-WithRetry([scriptblock]$Action, [string]$Description) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw "$Description failed after $attempt attempts: $($_.Exception.Message)"
            }

            Write-Host "$Description failed (attempt $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

$repository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "meziantou/prebuilt" }
$release = Invoke-WithRetry { Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/tags/$([uri]::EscapeDataString($Tag))" -Headers $headers } "Getting release $Tag"
$assets = @{}
foreach ($asset in $release.assets) {
    $assets[$asset.name] = $asset
}

foreach ($name in "build-keys.json", "prebuilt-tools.json") {
    if (-not $assets.ContainsKey($name)) {
        throw "Release $Tag has no $name"
    }
}

$buildKeys = Invoke-WithRetry { Invoke-RestMethod -Uri $assets["build-keys.json"].browser_download_url } "Downloading build-keys.json"
$manifest = Invoke-WithRetry { Invoke-RestMethod -Uri $assets["prebuilt-tools.json"].browser_download_url } "Downloading prebuilt-tools.json"

$unit = $buildKeys.units.PSObject.Properties[$Artifact]
if (-not $unit -or -not ($unit.Value.PSObject.Properties.Name -contains "files")) {
    throw "build-keys.json of release $Tag has no files for $Artifact"
}

foreach ($fileName in @($unit.Value.files)) {
    $entry = @($manifest.tools | Where-Object fileName -ceq $fileName)
    if ($entry.Count -ne 1) {
        throw "prebuilt-tools.json of release $Tag has $($entry.Count) entries for $fileName"
    }
    if (-not $assets.ContainsKey($fileName)) {
        throw "Release $Tag has no $fileName"
    }

    $path = Join-Path $PWD $fileName
    Invoke-WithRetry {
        Invoke-WebRequest -Uri $assets[$fileName].browser_download_url -OutFile $path
        $size = (Get-Item -LiteralPath $path).Length
        $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($size -ne $entry[0].size -or $sha256 -ne $entry[0].sha256) {
            Remove-Item -LiteralPath $path -Force
            throw "$fileName has $size bytes and SHA-256 $sha256, expected $($entry[0].size) bytes and $($entry[0].sha256)"
        }
    } "Downloading $fileName" | Out-Null

    Write-Host "$fileName ($($entry[0].size) bytes, $($entry[0].sha256)) from release $Tag"
}
