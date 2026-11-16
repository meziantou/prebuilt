<#
.SYNOPSIS
Downloads the files of build units from a release, instead of building them.

.DESCRIPTION
    ./scripts/Get-ReleaseFiles.ps1 -Tag <release> -Artifact <unit>[,<unit>...] -OutputPath <directory>

Used by the reuse-artifacts job for the build units scripts/Get-BuildPlan.ps1
marked as reused: the files the release recorded for each unit in
build-keys.json are written to <OutputPath>/<unit>, for the job to upload as
the artifact of the unit, as if its job had built them. Each file is checked
against the size and SHA-256 of prebuilt-tools.json.

Any failure is fatal: the jobs of the reused units do not run, so nothing can
build the files instead. Running the workflow again, or with the rebuild input,
recovers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [Parameter(Mandatory = $true)]
    [string[]]$Artifact,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 5,

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 8
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

# What to download, checked before any download: unit, file name, URL, size, SHA-256.
$downloads = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Artifact) {
    $unit = $buildKeys.units.PSObject.Properties[$name]
    if (-not $unit -or -not ($unit.Value.PSObject.Properties.Name -contains "files")) {
        throw "build-keys.json of release $Tag has no files for $name"
    }

    foreach ($fileName in @($unit.Value.files)) {
        $entry = @($manifest.tools | Where-Object fileName -ceq $fileName)
        if ($entry.Count -ne 1) {
            throw "prebuilt-tools.json of release $Tag has $($entry.Count) entries for $fileName"
        }
        if (-not $assets.ContainsKey($fileName)) {
            throw "Release $Tag has no $fileName"
        }

        $downloads.Add([pscustomobject]@{
            Unit     = $name
            FileName = $fileName
            Url      = $assets[$fileName].browser_download_url
            Size     = $entry[0].size
            Sha256   = $entry[0].sha256
        })
    }

    New-Item -ItemType Directory -Path (Join-Path $OutputPath $name) -Force | Out-Null
}

$outputDirectory = (Resolve-Path -LiteralPath $OutputPath).Path
$downloads | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    $file = $_
    $path = Join-Path $using:outputDirectory $file.Unit $file.FileName
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest -Uri $file.Url -OutFile $path
            $size = (Get-Item -LiteralPath $path).Length
            $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($size -ne $file.Size -or $sha256 -ne $file.Sha256) {
                Remove-Item -LiteralPath $path -Force
                throw "$($file.FileName) has $size bytes and SHA-256 $sha256, expected $($file.Size) bytes and $($file.Sha256)"
            }
            break
        } catch {
            if ($attempt -ge $using:MaxAttempts) {
                throw "Downloading $($file.FileName) failed after $attempt attempts: $($_.Exception.Message)"
            }

            Write-Host "Downloading $($file.FileName) failed (attempt $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    Write-Host "$($file.Unit)/$($file.FileName) ($($file.Size) bytes, $($file.Sha256))"
}

Write-Host "Downloaded $($downloads.Count) files of $($Artifact.Count) units from release $Tag"
