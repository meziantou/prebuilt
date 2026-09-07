[CmdletBinding()]
param(
    [string]$WorkflowPath = ".github\workflows\ci.yml",
    [string[]]$Variables,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $headers = @{
        "User-Agent" = "prebuilt-version-updater"
        "Accept" = "application/vnd.github+json"
    }

    Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers
}

function Get-ReleaseTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [switch]$TrimV
    )

    $response = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repository/releases/latest"
    $tag = "$($response.tag_name)".Trim()
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw "Unable to get latest release tag for '$Repository'."
    }

    if ($TrimV) {
        return $tag.TrimStart("v", "V")
    }

    return $tag
}

function Get-ZopfliVersion {
    $tags = Invoke-GitHubApi -Uri "https://api.github.com/repos/google/zopfli/tags?per_page=50"
    $versions =
        foreach ($tag in $tags) {
            if ($tag.name -match "^zopfli-(?<version>\d+\.\d+\.\d+)$") {
                [PSCustomObject]@{
                    Version = [version]$Matches["version"]
                    Text = $Matches["version"]
                }
            }
        }

    if (-not $versions) {
        throw "Unable to determine latest Zopfli version."
    }

    return ($versions | Sort-Object Version -Descending | Select-Object -First 1).Text
}

function Get-FFmpegVersion {
    $release = Invoke-GitHubApi -Uri "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest"
    $assets = @($release.assets)
    if (-not $assets) {
        throw "Unable to determine FFmpeg version (release has no assets)."
    }

    $requiredPatterns = @(
        "^ffmpeg-.*-win64-gpl-(?<version>\d+(?:\.\d+){1,2})\.zip$",
        "^ffmpeg-.*-winarm64-gpl-(?<version>\d+(?:\.\d+){1,2})\.zip$",
        "^ffmpeg-.*-linux64-gpl-(?<version>\d+(?:\.\d+){1,2})\.tar\.xz$",
        "^ffmpeg-.*-linuxarm64-gpl-(?<version>\d+(?:\.\d+){1,2})\.tar\.xz$"
    )

    $versionCounts = @{}
    foreach ($asset in $assets) {
        foreach ($pattern in $requiredPatterns) {
            if ($asset.name -cmatch $pattern) {
                $version = $Matches["version"]
                if (-not $versionCounts.ContainsKey($version)) {
                    $versionCounts[$version] = 0
                }

                $versionCounts[$version]++
            }
        }
    }

    $candidateVersions =
        foreach ($entry in $versionCounts.GetEnumerator()) {
            if ($entry.Value -ge $requiredPatterns.Count) {
                [PSCustomObject]@{
                    Version = [version]$entry.Key
                    Text = $entry.Key
                }
            }
        }

    if (-not $candidateVersions) {
        throw "Unable to determine FFmpeg version from latest FFmpeg-Builds release assets."
    }

    return ($candidateVersions | Sort-Object Version -Descending | Select-Object -First 1).Text
}

function Select-LatestVersion {
    param(
        [string[]]$Names,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $versions =
        foreach ($name in $Names) {
            if ($name -match $Pattern) {
                [PSCustomObject]@{
                    Version = [version]$Matches["version"]
                    Text = $Matches["version"]
                }
            }
        }

    if (-not $versions) {
        throw "Unable to determine the latest version for '$Description'."
    }

    return ($versions | Sort-Object Version -Descending | Select-Object -First 1).Text
}

function Get-LatestTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [string]$Pattern = "^v?(?<version>\d+(?:\.\d+){1,3})$"
    )

    $tags = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repository/tags?per_page=100"
    return Select-LatestVersion -Names ($tags | ForEach-Object { $_.name }) -Pattern $Pattern -Description $Repository
}

function Get-LatestGitLabTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,
        [string]$Registry = "https://gitlab.com",
        [string]$Pattern = "^v(?<version>\d+(?:\.\d+){1,3})$"
    )

    $encoded = [uri]::EscapeDataString($ProjectPath)
    $tags = Invoke-RestMethod -Method Get -Uri "$Registry/api/v4/projects/$encoded/repository/tags?per_page=100"
    return Select-LatestVersion -Names ($tags | ForEach-Object { $_.name }) -Pattern $Pattern -Description $ProjectPath
}

function Get-LatestAomVersion {
    $refs = & git ls-remote --tags https://aomedia.googlesource.com/aom
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list tags for libaom."
    }

    $names = foreach ($ref in $refs) { ($ref -split "/")[-1] }
    return Select-LatestVersion -Names $names -Pattern "^v(?<version>\d+(?:\.\d+){1,3})$" -Description "libaom"
}

function Get-LatestX265Version {
    $response = Invoke-RestMethod -Method Get -Uri "https://api.bitbucket.org/2.0/repositories/multicoreware/x265_git/refs/tags?pagelen=100"
    return Select-LatestVersion -Names ($response.values | ForEach-Object { $_.name }) -Pattern "^(?<version>\d+(?:\.\d+){1,3})$" -Description "x265"
}

function Get-LatestX264Commit {
    $refs = & git ls-remote https://code.videolan.org/videolan/x264.git stable
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the x264 stable branch."
    }

    return ($refs -split "\s+")[0]
}

function Set-YamlVariableValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$VariableName,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $pattern = "(?m)^(?<indent>[ \t]*)$([regex]::Escape($VariableName)):[ \t]*(?:(?<quoted>""(?<quotedValue>[^""]*)"")|(?<bare>[^\s#]+))(?<comment>[ \t]*#.*)?$"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        return [PSCustomObject]@{
            Found = $false
            PreviousValue = $null
            CurrentValue = $Value
            Content = $Content
        }
    }

    $quoted = $match.Groups["quoted"].Success
    $existingValue = if ($quoted) { $match.Groups["quotedValue"].Value } else { $match.Groups["bare"].Value }
    $comment = if ($match.Groups["comment"].Success) { $match.Groups["comment"].Value } else { "" }
    $indent = $match.Groups["indent"].Value
    $replacementValue = if ($quoted) { "`"$Value`"" } else { $Value }
    $replacement = "$indent${VariableName}: $replacementValue$comment"
    $updatedContent = [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)

    return [PSCustomObject]@{
        Found = $true
        PreviousValue = $existingValue
        CurrentValue = $Value
        Content = $updatedContent
    }
}

$resolvedWorkflowPath = Resolve-Path -LiteralPath $WorkflowPath
$workflowContent = Get-Content -LiteralPath $resolvedWorkflowPath -Raw
if ([string]::IsNullOrEmpty($workflowContent)) {
    throw "Workflow file '$($resolvedWorkflowPath.Path)' is empty."
}

$availableLatestVersions = [ordered]@{
    "ZOPFLI_VERSION" = Get-ZopfliVersion
    "OXIPNG_VERSION" = Get-ReleaseTag -Repository "shssoichiro/oxipng" -TrimV
    "FFMPEG_VERSION" = Get-FFmpegVersion
    "FFMPEG_CUSTOM_VERSION" = Get-LatestTag -Repository "FFmpeg/FFmpeg" -Pattern "^n(?<version>\d+\.\d+\.\d+)$"
    "LLVM_MINGW_VERSION" = Get-ReleaseTag -Repository "mstorsjo/llvm-mingw"
    "ZLIB_VERSION" = Get-LatestTag -Repository "madler/zlib"
    "BROTLI_VERSION" = Get-LatestTag -Repository "google/brotli"
    "HWY_VERSION" = Get-LatestTag -Repository "google/highway"
    "JXL_VERSION" = Get-ReleaseTag -Repository "libjxl/libjxl" -TrimV
    "WEBP_VERSION" = Get-LatestTag -Repository "webmproject/libwebp"
    "OPUS_VERSION" = Get-ReleaseTag -Repository "xiph/opus" -TrimV
    "LIBVPX_VERSION" = Get-LatestTag -Repository "webmproject/libvpx"
    "AOM_VERSION" = Get-LatestAomVersion
    "SVT_AV1_VERSION" = Get-LatestGitLabTag -ProjectPath "AOMediaCodec/SVT-AV1"
    "DAV1D_VERSION" = Get-LatestGitLabTag -ProjectPath "videolan/dav1d" -Registry "https://code.videolan.org" -Pattern "^(?<version>\d+(?:\.\d+){1,3})$"
    "X265_VERSION" = Get-LatestX265Version
    "X264_COMMIT" = Get-LatestX264Commit
}

$selectedVariableNames =
    if ($Variables -and $Variables.Count -gt 0) {
        @($Variables)
    } else {
        @($availableLatestVersions.Keys)
    }

$latestVersions = [ordered]@{}
foreach ($name in $selectedVariableNames) {
    if (-not $availableLatestVersions.Contains($name)) {
        $supported = ($availableLatestVersions.Keys -join ", ")
        throw "Unsupported variable '$name'. Supported values: $supported"
    }

    $latestVersions[$name] = $availableLatestVersions[$name]
}

$updates = @()
$updatedWorkflowContent = $workflowContent
foreach ($entry in $latestVersions.GetEnumerator()) {
    $result = Set-YamlVariableValue -Content $updatedWorkflowContent -VariableName $entry.Key -Value $entry.Value
    if (-not $result.Found) {
        throw "Variable '$($entry.Key)' was not found in '$($resolvedWorkflowPath.Path)'."
    }

    $updatedWorkflowContent = $result.Content
    $updates += [PSCustomObject]@{
        Variable = $entry.Key
        PreviousValue = $result.PreviousValue
        CurrentValue = $result.CurrentValue
        Changed = $result.PreviousValue -cne $result.CurrentValue
    }
}

$changed = $updates | Where-Object Changed
if (-not $WhatIf) {
    Set-Content -LiteralPath $resolvedWorkflowPath -Value $updatedWorkflowContent -NoNewline
}

foreach ($update in $updates) {
    if ($update.Changed) {
        Write-Output "$($update.Variable): $($update.PreviousValue) -> $($update.CurrentValue)"
    } else {
        Write-Output "$($update.Variable): up-to-date ($($update.CurrentValue))"
    }
}

if ($WhatIf) {
    Write-Output "WhatIf: no files were written."
} elseif ($changed.Count -eq 0) {
    Write-Output "No changes were needed."
} else {
    Write-Output "Updated '$($resolvedWorkflowPath.Path)' with latest versions."
}
