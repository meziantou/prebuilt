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
    $tags = Invoke-GitHubApi -Uri "https://api.github.com/repos/FFmpeg/FFmpeg/tags?per_page=100"
    $versions =
        foreach ($tag in $tags) {
            if ($tag.name -match "^n(?<version>\d+(?:\.\d+){1,2})$") {
                [PSCustomObject]@{
                    Version = [version]$Matches["version"]
                    Text = $Matches["version"]
                }
            }
        }

    if (-not $versions) {
        throw "Unable to determine latest FFmpeg version from FFmpeg tags."
    }

    return ($versions | Sort-Object Version -Descending | Select-Object -First 1).Text
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

$latestFFmpegVersion = Get-FFmpegVersion
$availableLatestVersions = [ordered]@{
    "ZOPFLI_VERSION" = Get-ZopfliVersion
    "OXIPNG_VERSION" = Get-ReleaseTag -Repository "shssoichiro/oxipng" -TrimV
    "FFMPEG_VERSION" = $latestFFmpegVersion
    "FFMPEG_SOURCE_REF" = "n$latestFFmpegVersion"
    "RCLONE_VERSION" = Get-ReleaseTag -Repository "rclone/rclone"
    "IMAGEMAGICK_VERSION" = Get-ReleaseTag -Repository "ImageMagick/ImageMagick" -TrimV
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
