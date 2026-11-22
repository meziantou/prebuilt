<#
.SYNOPSIS
Decides which builds and tests of a CI run can be taken from the latest release.

.DESCRIPTION
    ./scripts/Get-BuildPlan.ps1 [-OutputPath build-keys/build-keys.json]

Most CI runs change one tool, or none, yet every job would rebuild everything,
and several of them wait for a macOS runner to do it. This script runs first,
on ubuntu, and gives every unit below a build key: the SHA-256 of everything its
output depends on.

- the block of its job in ci.yml, without its needs: and if:, which only
  decide when the job runs (the CI logic around a unit can change without
  rebuilding it);
- the scripts that block runs, and the files these scripts use through
  $SCRIPT_DIR, recursively;
- the value of every top-level env variable of ci.yml any of these mention:
  the tool version, the dependency versions, ALPINE_IMAGE, LLVM_MINGW_VERSION...

The latest release records the key of every unit in build-keys.json
(scripts/Merge-ReleaseArtifacts.ps1). A build unit whose key did not change is
reused: its job, or its leg of a matrix job, does not run, and the
reuse-artifacts job uploads the files of that release under the name of its
artifact (scripts/Get-ReleaseFiles.ps1). A test unit is reused when its key did
not change and every binary it tests was reused: it does not run.

Outputs, in $GITHUB_OUTPUT:
- build: {"<job>": true|false, ...}, whether a job has a unit to build or test,
  the condition of the job: fromJSON(needs.build-plan.outputs.build)['<job>'];
- matrix: {"<job>": [{"rid": ..., "os": ...}, ...], ...}, the matrix of each
  matrix job, its units to build or test only;
- reused: ["<unit>", ...], the reused build units, for reuse-artifacts;
- release: the tag of the release the reused files come from.

-OutputPath gets the key of every unit, for create-release to record.

Setting FORCE_REBUILD to true (the rebuild input of workflow_dispatch) reuses
nothing. Any problem with the release (none yet, no build-keys.json, a network
error) also reuses nothing, with a warning: this script never fails a run
because of the release.

The runner label of a unit is part of its key (its matrix entry, or its job
block), but runner images are not, on purpose: a new macos-latest does not
rebuild anything until a tool changes, or a run asks for a rebuild.
#>
[CmdletBinding()]
param(
    [string]$WorkflowPath = ".github/workflows/ci.yml",

    [string]$OutputPath = "build-keys/build-keys.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Bump to change every key at once, e.g. when the way keys are computed changes.
$keyFormat = "v1"

# Unit -> its job in ci.yml and the runtime identifier it is built or tested
# for. A build unit is named after the artifact its job uploads; a test unit
# lists the build units whose binaries it tests (inputs).
#
# The units of a matrix job also have their matrix entry (matrix): the matrix of
# the job is the entries of the units this run builds (the matrix output), so
# that a reused unit starts no job at all. The entry is part of the key: a new
# runner rebuilds the unit. Linux and Windows binaries are built in Alpine and
# with llvm-mingw on ubuntu, unless an override below says otherwise.
$units = [ordered]@{}
$rids = "linux-x64", "linux-arm64", "win-x64", "osx-arm64"
$defaultRunners = @{
    "linux-x64"   = "ubuntu-latest"
    "linux-arm64" = "ubuntu-24.04-arm"
    "win-x64"     = "ubuntu-latest"
    "osx-arm64"   = "macos-latest"
}
function New-MatrixEntry([string]$Rid) {
    return [ordered]@{ rid = $Rid; os = $defaultRunners[$Rid] }
}

foreach ($job in "libavif", "libjxl", "jxl-oxide", "woff2", "harfbuzz", "openjpeg", "openjph", "openexr", "iso-jpeg", "radiance", "imagemagick", "psd-tools", "astcenc", "basisu", "ktx-software", "libraw", "hm-scm", "iccdev", "opencv", "openimageio", "dng-sdk", "libheif", "hm", "qpdf", "mupdf", "poppler", "arlington", "verapdf", "pdfium", "zint", "zxing-cpp", "zbar", "sevenzip", "unrar", "pngquant", "mozjpeg") {
    foreach ($rid in $rids) {
        $units["binaries-$job-$rid"] = @{ job = $job; rid = $rid; matrix = New-MatrixEntry $rid }
    }
}
# libavif repackages the Windows and macOS binaries of its release.
$units["binaries-libavif-win-x64"].matrix.os = "windows-latest"
$units["binaries-libavif-win-x64"].matrix.archive = "windows-artifacts.zip"
$units["binaries-libavif-osx-arm64"].matrix.archive = "macOS-artifacts.zip"
$units["binaries-jxl-oxide-win-x64"].matrix.os = "windows-latest"
# pdfium cross-compiles linux-arm64 on x64 (pdfium-linux-arm64-test runs it)
# and builds win-x64 with the toolchain of Chromium on Windows.
$units["binaries-pdfium-linux-arm64"].matrix.os = "ubuntu-latest"
$units["binaries-pdfium-win-x64"].matrix.os = "windows-latest"

# libwebp repackages the binaries of its release, on the runner of each target.
$libwebpArchives = @{
    "linux-x64"   = "linux-x86-64.tar.gz"
    "linux-arm64" = "linux-aarch64.tar.gz"
    "win-x64"     = "windows-x64.zip"
    "osx-arm64"   = "mac-arm64.tar.gz"
}
foreach ($rid in $rids) {
    $entry = New-MatrixEntry $rid
    $entry.archive = $libwebpArchives[$rid]
    $units["binaries-libwebp-$rid"] = @{ job = "libwebp"; rid = $rid; matrix = $entry }
}
$units["binaries-libwebp-win-x64"].matrix.os = "windows-latest"

# zopfli is built from source; oxipng and pngout repackage the binaries of
# their releases. One job per target, named as its artifact.
$singleTargetArtifacts = [ordered]@{
    "linux-x64"   = "linux"
    "linux-arm64" = "linux-arm64"
    "win-x64"     = "windows"
    "osx-arm64"   = "osx-arm64"
}
foreach ($tool in "zopfli", "oxipng", "pngout") {
    foreach ($rid in $singleTargetArtifacts.Keys) {
        $job = "$tool-$($singleTargetArtifacts[$rid])"
        $units["binaries-$job"] = @{ job = $job; rid = $rid }
    }
}

$ffmpegArtifacts = [ordered]@{
    "linux-x64"   = "binaries-ffmpeg-linux"
    "linux-arm64" = "binaries-ffmpeg-linux-arm64"
    "win-x64"     = "binaries-ffmpeg-windows"
    "win-arm64"   = "binaries-ffmpeg-windows-arm64"
    "osx-arm64"   = "binaries-ffmpeg-osx-arm64"
}
foreach ($rid in $ffmpegArtifacts.Keys) {
    $artifact = $ffmpegArtifacts[$rid]
    $units[$artifact] = @{ job = $artifact -replace '^binaries-', ''; rid = $rid }
}

foreach ($job in "libjxl", "woff2", "harfbuzz", "openjpeg", "openjph", "openexr", "iso-jpeg", "radiance", "imagemagick", "astcenc", "basisu", "ktx-software", "libraw", "hm-scm", "iccdev", "opencv", "openimageio", "dng-sdk", "libheif", "hm", "qpdf", "mupdf", "poppler", "arlington", "verapdf", "zint", "sevenzip", "unrar", "pngquant", "mozjpeg") {
    $units["$job-windows-test"] = @{ job = "$job-windows-test"; rid = "win-x64"; inputs = @("binaries-$job-win-x64") }
}
# The barcode readers are tested with the barcodes zint writes.
foreach ($job in "zxing-cpp", "zbar") {
    $units["$job-windows-test"] = @{ job = "$job-windows-test"; rid = "win-x64"; inputs = @("binaries-$job-win-x64", "binaries-zint-win-x64") }
}
# psd-tools is tested with the PSD files magick writes, and the other way around.
$units["psd-tools-windows-test"] = @{ job = "psd-tools-windows-test"; rid = "win-x64"; inputs = @("binaries-psd-tools-win-x64", "binaries-imagemagick-win-x64") }
$units["binaries-directxtex-win-x64"] = @{ job = "directxtex"; rid = "win-x64"; matrix = New-MatrixEntry "win-x64" }
$units["directxtex-windows-test"] = @{ job = "directxtex-windows-test"; rid = "win-x64"; inputs = @("binaries-directxtex-win-x64") }
# pdfium builds linux-arm64 on an x64 machine: this job runs it.
$units["pdfium-linux-arm64-test"] = @{ job = "pdfium-linux-arm64-test"; rid = "linux-arm64"; inputs = @("binaries-pdfium-linux-arm64") }
$units["ffmpeg-windows-test"] = @{ job = "ffmpeg-windows-test"; rid = "win-x64"; inputs = @("binaries-ffmpeg-windows") }
$units["ffmpeg-windows-arm64-test"] = @{ job = "ffmpeg-windows-arm64-test"; rid = "win-arm64"; inputs = @("binaries-ffmpeg-windows-arm64") }
foreach ($rid in $rids) {
    $entry = New-MatrixEntry $rid
    $entry.ffmpeg = $ffmpegArtifacts[$rid]
    $units["hevc-test-$rid"] = @{ job = "hevc-test"; rid = $rid; inputs = @($ffmpegArtifacts[$rid], "binaries-libheif-$rid", "binaries-hm-$rid"); matrix = $entry }
}
$units["hevc-test-win-x64"].matrix.os = "windows-latest"

# The scripts of the reuse itself change no binary.
$excludedFiles = "Get-BuildPlan.ps1", "Get-ReleaseFiles.ps1", "Merge-ReleaseArtifacts.ps1", "upload-reused-artifacts.mjs"
# VERSION is the release version, bumped by every release; the word is also in
# comments of the ffmpeg scripts. FORCE_REBUILD would make a forced build
# record a key the next run never matches.
$excludedVariables = "VERSION", "FORCE_REBUILD"
# Inputs that only the builds of some runtime identifiers use, but that a job
# or a script mentions for all of them: an llvm-mingw bump rebuilds no Linux
# or macOS binary.
$ridOnly = @{
    "ALPINE_IMAGE"          = "^linux-"
    "docker-pull.sh"        = "^linux-"
    "LLVM_MINGW_VERSION"    = "^win-"
    "mingw-toolchain.cmake" = "^win-"
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$workflowLines = (Get-Content -LiteralPath (Join-Path $repositoryRoot $WorkflowPath) -Raw) -replace "`r`n", "`n" -split "`n"

function Get-TopLevelBlock([string]$Name) {
    $start = [Array]::IndexOf($workflowLines, "${Name}:")
    if ($start -lt 0) {
        throw "No top-level '${Name}:' in $WorkflowPath"
    }

    $end = $start + 1
    while ($end -lt $workflowLines.Count -and $workflowLines[$end] -notmatch '^\S') {
        $end++
    }

    return $workflowLines[($start + 1)..($end - 1)]
}

$jobLines = Get-TopLevelBlock "jobs"
$variableNames = @(Get-TopLevelBlock "env" | ForEach-Object { if ($_ -match '^  ([A-Z][A-Z0-9_]*):') { $Matches[1] } } | Where-Object { $_ -notin $excludedVariables })

# The lines of a job, up to the next job or the comment block above it.
function Get-JobBlock([string]$Job) {
    $start = [Array]::IndexOf($jobLines, "  ${Job}:")
    if ($start -lt 0) {
        throw "No job '$Job' in $WorkflowPath"
    }

    $end = $start + 1
    while ($end -lt $jobLines.Count -and $jobLines[$end] -notmatch '^  \S') {
        $end++
    }

    return ($jobLines[$start..($end - 1)] -join "`n").TrimEnd()
}

function Read-RepositoryFile([string]$RelativePath) {
    $path = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$RelativePath is referenced but does not exist"
    }

    return (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
}

# What the keys of a job are made of, before the filter of $ridOnly.
$jobInputs = @{}
function Get-JobInputs([string]$Job) {
    if ($jobInputs.ContainsKey($Job)) {
        return $jobInputs[$Job]
    }

    $block = (Get-JobBlock $Job) -split "`n" | Where-Object { $_ -notmatch '^    (needs|if):' }
    $block = $block -join "`n"

    # Only the job references scripts by their path: in the scripts, a
    # "scripts/..." is a comment pointing at another script, whereas
    # $SCRIPT_DIR/... is a file they read or run.
    $files = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($match in [regex]::Matches($block, 'scripts/([A-Za-z0-9_.-]+)')) {
        $pending.Enqueue($match.Groups[1].Value)
    }
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        if ($files.ContainsKey($name) -or $name -in $excludedFiles) {
            continue
        }

        $content = Read-RepositoryFile "scripts/$name"
        $files[$name] = $content
        foreach ($match in [regex]::Matches($content, '\$\{?SCRIPT_DIR\}?/([A-Za-z0-9_.-]+)')) {
            $pending.Enqueue($match.Groups[1].Value)
        }
    }

    $text = $block + "`n" + ($files.Values -join "`n")
    $variables = [ordered]@{}
    foreach ($name in $variableNames | Sort-Object) {
        if ($text -match "\b$name\b") {
            $value = [Environment]::GetEnvironmentVariable($name)
            # An empty value would silently drop the variable from the key.
            if ([string]::IsNullOrEmpty($value)) {
                throw "$name is not set (needed by the key of $Job)"
            }
            $variables[$name] = $value
        }
    }

    $jobInputs[$Job] = @{
        block     = $block
        files     = $files
        variables = $variables
    }
    return $jobInputs[$Job]
}

function Get-Sha256Hex([string]$Text) {
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-UnitKey([string]$Unit) {
    $Job = $units[$Unit].job
    $Rid = $units[$Unit].rid
    $inputs = Get-JobInputs $Job
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("$keyFormat`nrid=$Rid`n")
    if ($units[$Unit].ContainsKey("matrix")) {
        [void]$builder.Append("matrix=$(ConvertTo-Json $units[$Unit].matrix -Compress)`n")
    }
    foreach ($name in $inputs.variables.Keys) {
        if (-not $ridOnly.ContainsKey($name) -or $Rid -match $ridOnly[$name]) {
            [void]$builder.Append("$name=$($inputs.variables[$name])`n")
        }
    }
    [void]$builder.Append("== $WorkflowPath $Job ==`n$($inputs.block)`n")
    foreach ($name in $inputs.files.Keys) {
        if (-not $ridOnly.ContainsKey($name) -or $Rid -match $ridOnly[$name]) {
            [void]$builder.Append("== scripts/$name ==`n$($inputs.files[$name])`n")
        }
    }

    return Get-Sha256Hex $builder.ToString()
}

$keys = [ordered]@{}
foreach ($unit in $units.Keys) {
    $keys[$unit] = Get-UnitKey $unit
}

foreach ($job in $jobInputs.Keys | Sort-Object) {
    Write-Host "::group::Key inputs of $job"
    Write-Host "Files: $($jobInputs[$job].files.Keys -join ', ')"
    Write-Host "Variables: $($jobInputs[$job].variables.Keys -join ', ')"
    Write-Host "::endgroup::"
}

function Invoke-WithRetry([scriptblock]$Action, [string]$Description) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        } catch {
            # Not found is an answer, not a transient failure.
            $notFound = $_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and [int]$_.Exception.Response.StatusCode -eq 404
            if ($notFound -or $attempt -ge 5) {
                throw
            }

            Write-Host "$Description failed (attempt $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

# The previous keys: unit -> { key, files } from build-keys.json of the latest release.
$release = ""
$previous = @{}
$assetNames = @()
$reason = $null
if ($env:FORCE_REBUILD -eq "true") {
    $reason = "rebuild requested"
} else {
    try {
        $headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
        if ($env:GH_TOKEN) {
            $headers.Authorization = "Bearer $env:GH_TOKEN"
        }

        $repository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "meziantou/prebuilt" }
        $latest = Invoke-WithRetry { Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -Headers $headers } "Getting the latest release"
        $assetNames = @($latest.assets | ForEach-Object name)
        $buildKeysAsset = $latest.assets | Where-Object name -eq "build-keys.json"
        if (-not $buildKeysAsset) {
            $reason = "release $($latest.tag_name) has no build-keys.json"
        } elseif ("prebuilt-tools.json" -notin $assetNames) {
            $reason = "release $($latest.tag_name) has no prebuilt-tools.json"
        } else {
            $buildKeys = Invoke-WithRetry { Invoke-RestMethod -Uri $buildKeysAsset.browser_download_url } "Downloading build-keys.json"
            foreach ($property in $buildKeys.units.PSObject.Properties) {
                $previous[$property.Name] = $property.Value
            }
            $release = $latest.tag_name
        }
    } catch {
        $reason = "cannot read the latest release: $($_.Exception.Message)"
    }

    if ($reason) {
        Write-Host "::warning::Nothing is reused, $reason"
    }
}

$reuse = [ordered]@{}
$results = [ordered]@{}
foreach ($unit in $units.Keys) {
    $definition = $units[$unit]
    $recorded = $previous[$unit]
    $result = if ($reason) {
        $reason
    } elseif (-not $recorded) {
        "not in release $release"
    } elseif ($recorded.key -ne $keys[$unit]) {
        "inputs changed"
    } elseif ($definition.ContainsKey("inputs")) {
        $rebuilt = @($definition.inputs | Where-Object { -not $reuse[$_] })
        if ($rebuilt.Count -gt 0) { "$($rebuilt -join ', ') rebuilt" } else { $null }
    } else {
        $files = @($recorded.PSObject.Properties.Name -contains "files" ? $recorded.files : @())
        $missing = @($files | Where-Object { $_ -notin $assetNames })
        if ($files.Count -eq 0) { "no files recorded" } elseif ($missing.Count -gt 0) { "$($missing -join ', ') not in release $release" } else { $null }
    }

    $reuse[$unit] = $null -eq $result
    $results[$unit] = $result
}

$summary = [System.Text.StringBuilder]::new()
[void]$summary.Append("### Build plan`n`n")
[void]$summary.Append($(if ($release) { "Previous release: $release`n`n" } else { "No previous build keys: $reason`n`n" }))
[void]$summary.Append("| Unit | Key | Result |`n|---|---|---|`n")
foreach ($unit in $units.Keys) {
    $text = if ($reuse[$unit]) { "reused" } else { "built: $($results[$unit])" }
    [void]$summary.Append("| $unit | ``$($keys[$unit].Substring(0, 12))`` | $text |`n")
    Write-Host ("{0,-36} {1}" -f $unit, $text)
}
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary.ToString()
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$keyFile = [ordered]@{ units = [ordered]@{} }
foreach ($unit in $units.Keys) {
    $keyFile.units[$unit] = [ordered]@{
        key  = $keys[$unit]
        kind = if ($units[$unit].ContainsKey("inputs")) { "test" } else { "build" }
    }
}
ConvertTo-Json $keyFile -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

# build: job -> whether it has a unit to build or test. matrix: matrix job ->
# the entries of these units. reused: the reused build units, whose files the
# reuse-artifacts job uploads.
$build = [ordered]@{}
$matrix = [ordered]@{}
foreach ($unit in $units.Keys) {
    $job = $units[$unit].job
    if (-not $build.Contains($job)) {
        $build[$job] = $false
    }
    if ($units[$unit].ContainsKey("matrix") -and -not $matrix.Contains($job)) {
        $matrix[$job] = [System.Collections.Generic.List[object]]::new()
    }
    if (-not $reuse[$unit]) {
        $build[$job] = $true
        if ($units[$unit].ContainsKey("matrix")) {
            $matrix[$job].Add($units[$unit].matrix)
        }
    }
}
$reused = [System.Collections.Generic.List[string]]::new()
foreach ($unit in $units.Keys) {
    if ($reuse[$unit] -and -not $units[$unit].ContainsKey("inputs")) {
        $reused.Add($unit)
    }
}

$outputs = [ordered]@{
    build   = ConvertTo-Json $build -Compress
    matrix  = ConvertTo-Json $matrix -Compress -Depth 5
    reused  = ConvertTo-Json -InputObject $reused.ToArray() -Compress
    release = $release
}
foreach ($name in $outputs.Keys) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$name=$($outputs[$name])"
    } else {
        Write-Host "$name=$($outputs[$name])"
    }
}
