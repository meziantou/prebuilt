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

function Get-LatestWoff2Commit {
    $refs = & git ls-remote https://github.com/google/woff2.git master
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the woff2 master branch."
    }

    return ($refs -split "\s+")[0]
}

function Get-LatestStbCommit {
    $refs = & git ls-remote https://github.com/nothings/stb.git master
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the stb master branch."
    }

    return ($refs -split "\s+")[0]
}

# GraphicsMagick is released on SourceForge only.
function Get-LatestGraphicsMagickVersion {
    $feed = Invoke-RestMethod -Method Get -Uri "https://sourceforge.net/projects/graphicsmagick/rss?path=/graphicsmagick"
    $names = $feed | ForEach-Object { if ("$($_.title.InnerText)$($_.title)" -match "/graphicsmagick/(\d+\.\d+\.\d+)/GraphicsMagick-\1\.tar\.xz") { $Matches[1] } }
    return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+\.\d+)$" -Description "GraphicsMagick"
}

function Get-LatestLibIconvVersion {
    $page = Invoke-RestMethod -Method Get -Uri "https://ftp.gnu.org/pub/gnu/libiconv/"
    $names = [regex]::Matches($page, "libiconv-(\d+\.\d+(?:\.\d+)?)\.tar\.gz") | ForEach-Object { $_.Groups[1].Value }
    return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+(?:\.\d+)?)$" -Description "libiconv"
}

# FreeType tags are VER-2-15-0.
function Get-LatestFreeTypeVersion {
    $tags = Invoke-GitHubApi -Uri "https://api.github.com/repos/freetype/freetype/tags?per_page=100"
    $names = $tags | ForEach-Object { if ($_.name -match "^VER-(\d+)-(\d+)-(\d+)$") { "$($Matches[1]).$($Matches[2]).$($Matches[3])" } }
    return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+\.\d+)$" -Description "FreeType"
}

function Get-LatestPopplerVersion {
    $page = Invoke-RestMethod -Method Get -Uri "https://poppler.freedesktop.org/releases.html"
    $names = [regex]::Matches($page, "poppler-(\d+\.\d+\.\d+)\.tar\.xz") | ForEach-Object { $_.Groups[1].Value }
    return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+\.\d+)$" -Description "Poppler"
}

# The NSS release and the NSPR version its source tarball bundles.
function Get-LatestNssRelease {
    $page = Invoke-RestMethod -Method Get -Uri "https://ftp.mozilla.org/pub/security/nss/releases/"
    $names = [regex]::Matches($page, "NSS_(\d+(?:_\d+)+)_RTM") | ForEach-Object { $_.Groups[1].Value -replace "_", "." }
    $nss = Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+(?:\.\d+)?)$" -Description "NSS"
    $tag = "NSS_" + ($nss -replace "\.", "_") + "_RTM"
    $files = Invoke-RestMethod -Method Get -Uri "https://ftp.mozilla.org/pub/security/nss/releases/$tag/src/"
    $match = [regex]::Match($files, "nss-$([regex]::Escape($nss))-with-nspr-(\d+\.\d+(?:\.\d+)?)\.tar\.gz")
    if (-not $match.Success) {
        throw "No NSS $nss source tarball with NSPR."
    }

    return @{ NSS = $nss; NSPR = $match.Groups[1].Value }
}

function Get-LatestArlingtonCommit {
    $refs = & git ls-remote https://github.com/pdf-association/arlington-pdf-model.git master
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the Arlington master branch."
    }

    return ($refs -split "\s+")[0]
}

# veraPDF releases have an even minor version; the odd ones are development builds.
function Get-LatestVeraPdfVersion {
    $page = Invoke-RestMethod -Method Get -Uri "https://software.verapdf.org/releases/"
    $minors = [regex]::Matches($page, 'href="(\d+\.\d+)/"') | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { ([version]$_).Minor % 2 -eq 0 } | Sort-Object { [version]$_ } -Descending
    foreach ($minor in $minors) {
        $files = Invoke-RestMethod -Method Get -Uri "https://software.verapdf.org/releases/$minor/"
        $names = [regex]::Matches($files, "verapdf-greenfield-(\d+\.\d+\.\d+)-installer\.zip") | ForEach-Object { $_.Groups[1].Value }
        if ($names) {
            return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+\.\d+)$" -Description "veraPDF"
        }
    }

    throw "Unable to determine the latest veraPDF release."
}

# The latest Temurin release of the major version of TEMURIN_VERSION that has
# a JDK for every target: the platforms of a release are not published at once.
function Get-LatestTemurinVersion {
    $current = [regex]::Match($workflowContent, 'TEMURIN_VERSION: "(\d+)').Groups[1].Value
    $releases = Invoke-RestMethod -Method Get -Uri "https://api.adoptium.net/v3/info/release_names?release_type=ga&version=%5B$current%2C$([int]$current + 1)%29&page_size=10&sort_order=DESC"
    foreach ($release in $releases.releases) {
        $platforms = 0
        foreach ($platform in "os=linux&architecture=x64", "os=linux&architecture=aarch64", "os=mac&architecture=aarch64", "os=windows&architecture=x64") {
            try {
                $assets = Invoke-RestMethod -Method Get -Uri "https://api.adoptium.net/v3/assets/release_name/eclipse/$([uri]::EscapeDataString($release))?image_type=jdk&$platform"
                if ($assets.binaries | Where-Object { $_.image_type -eq "jdk" }) {
                    $platforms++
                }
            }
            catch {
            }
        }

        if ($platforms -eq 4) {
            return $release -replace "^jdk-", ""
        }
    }

    throw "No recent Temurin $current release has a JDK for every target."
}

# PDFium has no releases: the chromium/<N> branch of the latest release of
# bblanchon/pdfium-binaries, which builds it for every target.
function Get-LatestPdfiumVersion {
    $tag = Get-ReleaseTag -Repository "bblanchon/pdfium-binaries"
    if ($tag -notmatch "^chromium/(?<version>\d+)$") {
        throw "Unexpected pdfium-binaries release tag '$tag'."
    }

    return $Matches["version"]
}

function Get-LatestDepotToolsCommit {
    $refs = & git ls-remote https://chromium.googlesource.com/chromium/tools/depot_tools.git refs/heads/main
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the depot_tools main branch."
    }

    return ($refs -split "\s+")[0]
}

# MuPDF publishes its releases on mupdf.com; the GitHub mirror has their tags.
function Get-LatestMuPdfVersion {
    $refs = & git ls-remote --tags https://github.com/ArtifexSoftware/mupdf.git
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list tags for MuPDF."
    }

    $names = foreach ($ref in $refs) { ($ref -split "/")[-1] }
    return Select-LatestVersion -Names $names -Pattern "^(?<version>\d+\.\d+\.\d+)$" -Description "MuPDF"
}

function Get-LatestIsoJpegCommit {
    $refs = & git ls-remote https://github.com/thorfdbg/libjpeg.git master
    if ($LASTEXITCODE -ne 0 -or -not $refs) {
        throw "Unable to resolve the libjpeg master branch."
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
    "FFMPEG_VERSION" = Get-LatestTag -Repository "FFmpeg/FFmpeg" -Pattern "^n(?<version>\d+\.\d+\.\d+)$"
    "LLVM_MINGW_VERSION" = Get-ReleaseTag -Repository "mstorsjo/llvm-mingw"
    "ZLIB_VERSION" = Get-LatestTag -Repository "madler/zlib"
    "BROTLI_VERSION" = Get-LatestTag -Repository "google/brotli"
    "HWY_VERSION" = Get-LatestTag -Repository "google/highway"
    "JXL_VERSION" = Get-ReleaseTag -Repository "libjxl/libjxl" -TrimV
    "LIBPNG_VERSION" = Get-LatestTag -Repository "pnggroup/libpng" -Pattern "^v(?<version>\d+\.\d+\.\d+)$"
    "JXL_OXIDE_VERSION" = Get-ReleaseTag -Repository "tirr-c/jxl-oxide"
    "RUST_TOOLCHAIN" = Get-ReleaseTag -Repository "rust-lang/rust"
    "WEBP_VERSION" = Get-LatestTag -Repository "webmproject/libwebp"
    "LIBAVIF_VERSION" = Get-ReleaseTag -Repository "AOMediaCodec/libavif" -TrimV
    "HARFBUZZ_VERSION" = Get-ReleaseTag -Repository "harfbuzz/harfbuzz"
    "WOFF2_COMMIT" = Get-LatestWoff2Commit
    "OPENJPEG_VERSION" = Get-ReleaseTag -Repository "uclouvain/openjpeg" -TrimV
    "OPENJPH_VERSION" = Get-ReleaseTag -Repository "aous72/OpenJPH"
    "ISO_JPEG_COMMIT" = Get-LatestIsoJpegCommit
    "OPUS_VERSION" = Get-ReleaseTag -Repository "xiph/opus" -TrimV
    "LIBVPX_VERSION" = Get-LatestTag -Repository "webmproject/libvpx"
    "AOM_VERSION" = Get-LatestAomVersion
    "SVT_AV1_VERSION" = Get-LatestGitLabTag -ProjectPath "AOMediaCodec/SVT-AV1"
    "DAV1D_VERSION" = Get-LatestGitLabTag -ProjectPath "videolan/dav1d" -Registry "https://code.videolan.org" -Pattern "^(?<version>\d+(?:\.\d+){1,3})$"
    "X265_VERSION" = Get-LatestX265Version
    "KVAZAAR_VERSION" = Get-LatestTag -Repository "ultravideo/kvazaar" -Pattern "^v(?<version>\d+\.\d+\.\d+)$"
    "LIBDE265_VERSION" = Get-ReleaseTag -Repository "strukturag/libde265" -TrimV
    "LIBHEIF_VERSION" = Get-ReleaseTag -Repository "strukturag/libheif" -TrimV
    "HM_VERSION" = Get-LatestGitLabTag -ProjectPath "jvet/HM" -Registry "https://vcgit.hhi.fraunhofer.de" -Pattern "^HM-(?<version>\d+\.\d+)$"
    "X264_COMMIT" = Get-LatestX264Commit
    "QPDF_VERSION" = Get-ReleaseTag -Repository "qpdf/qpdf" -TrimV
    "LIBJPEG_TURBO_VERSION" = Get-ReleaseTag -Repository "libjpeg-turbo/libjpeg-turbo"
    "MUPDF_VERSION" = Get-LatestMuPdfVersion
    "POPPLER_VERSION" = Get-LatestPopplerVersion
    "FREETYPE_VERSION" = Get-LatestFreeTypeVersion
    "LCMS2_VERSION" = Get-LatestTag -Repository "mm2/Little-CMS" -Pattern "^lcms(?<version>\d+\.\d+(?:\.\d+)?)$"
    "NSS_VERSION" = (Get-LatestNssRelease).NSS
    "NSPR_VERSION" = (Get-LatestNssRelease).NSPR
    "ARLINGTON_COMMIT" = Get-LatestArlingtonCommit
    "VERAPDF_VERSION" = Get-LatestVeraPdfVersion
    "TEMURIN_VERSION" = Get-LatestTemurinVersion
    "PDFIUM_VERSION" = Get-LatestPdfiumVersion
    "DEPOT_TOOLS_COMMIT" = Get-LatestDepotToolsCommit
    "ZINT_VERSION" = Get-LatestTag -Repository "zint/zint" -Pattern "^(?<version>\d+\.\d+\.\d+)$"
    "ZXING_CPP_VERSION" = Get-ReleaseTag -Repository "zxing-cpp/zxing-cpp" -TrimV
    "STB_COMMIT" = Get-LatestStbCommit
    "ZBAR_VERSION" = Get-ReleaseTag -Repository "mchehab/zbar"
    "GRAPHICSMAGICK_VERSION" = Get-LatestGraphicsMagickVersion
    "LIBICONV_VERSION" = Get-LatestLibIconvVersion
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
