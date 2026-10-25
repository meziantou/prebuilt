[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BinariesPath,

    [Parameter(Mandatory = $true)]
    [string]$ReleaseVersion,

    [Parameter(Mandatory = $true)]
    [string]$DownloadBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Tool name -> key in versions.json. Every tool listed here must have at least
# one release file, and a release file whose tool is not listed fails the
# script, so a new tool cannot ship without a version (and the matching static
# property in src/Meziantou.Prebuilt/PrebuiltTools.cs).
$versionKeys = [ordered]@{
    "zopfli"           = "Zopfli"
    "oxipng"           = "Oxipng"
    "pngout"           = "Pngout"
    "ffmpeg"           = "FFmpeg"
    "ffprobe"          = "FFmpeg"
    "cwebp"            = "LibWebP"
    "dwebp"            = "LibWebP"
    "webpmux"          = "LibWebP"
    "anim_dump"        = "LibWebP"
    "avifenc"          = "LibAvif"
    "avifdec"          = "LibAvif"
    "cjxl"             = "LibJxl"
    "djxl"             = "LibJxl"
    "jxlinfo"          = "LibJxl"
    "jxl_from_tree"    = "LibJxl"
    "jxl-oxide"        = "JxlOxide"
    "hb-shape"         = "HarfBuzz"
    "hb-info"          = "HarfBuzz"
    "hb-subset"        = "HarfBuzz"
    "hb-vector"        = "HarfBuzz"
    "hb-raster"        = "HarfBuzz"
    "woff2_compress"   = "Woff2"
    "woff2_decompress" = "Woff2"
    "woff2_info"       = "Woff2"
    "opj_compress"     = "OpenJpeg"
    "opj_decompress"   = "OpenJpeg"
    "opj_dump"         = "OpenJpeg"
    "ojph_compress"    = "OpenJph"
    "ojph_expand"      = "OpenJph"
    "iso-jpeg"         = "IsoJpeg"
    "x265"             = "X265"
    "kvazaar"          = "Kvazaar"
    "dec265"           = "LibDe265"
    "heif-enc"         = "LibHeif"
    "heif-dec"         = "LibHeif"
    "heif-info"        = "LibHeif"
    "TAppEncoder"      = "HM"
    "TAppDecoder"      = "HM"
    "qpdf"             = "Qpdf"
    "mutool"           = "MuPdf"
    "pdftoppm"         = "Poppler"
    "pdftotext"        = "Poppler"
    "pdffonts"         = "Poppler"
    "pdfinfo"          = "Poppler"
    "pdfsig"           = "Poppler"
    "TestGrammar"      = "Arlington"
    "verapdf"          = "VeraPdf"
    "pdfium_test"      = "Pdfium"
    "zint"             = "Zint"
    "ZXingReader"      = "ZXingCpp"
    "zbarimg"          = "ZBar"
}

$versionsPath = Join-Path $BinariesPath "versions.json"
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json -AsHashtable

if (-not $DownloadBaseUrl.EndsWith("/")) {
    $DownloadBaseUrl += "/"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$tools = [System.Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath $BinariesPath -File | Sort-Object Name) {
    if ($file.Name -eq "versions.json" -or $file.FullName -eq $outputFullPath) {
        continue
    }

    # Other files in the binaries folder are not tools. A .tar.gz file is a tool
    # with the files it needs: its executable is at the root of the archive.
    if ($file.Name -cnotmatch '^(?<name>.+)-(?<rid>(linux|win|osx)-(x64|arm64))(\.exe|\.tar\.gz)?$') {
        Write-Host "Skipping $($file.Name)"
        continue
    }

    $name = $Matches["name"]
    $rid = $Matches["rid"]
    if (-not $versionKeys.Contains($name)) {
        throw "Unknown tool '$name' ($($file.Name)). Add it to `$versionKeys in $PSCommandPath."
    }

    $versionKey = $versionKeys[$name]
    if (-not $versions.ContainsKey($versionKey)) {
        throw "versions.json has no '$versionKey' entry (needed by $($file.Name))"
    }

    $tools.Add([ordered]@{
        name              = $name
        runtimeIdentifier = $rid
        version           = "$($versions[$versionKey])"
        fileName          = $file.Name
        size              = $file.Length
        sha256            = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

$missingTools = @($versionKeys.Keys | Where-Object { $name = $_; -not ($tools | Where-Object { $_.name -ceq $name }) })
if ($missingTools.Count -gt 0) {
    throw "No release file found for: $($missingTools -join ', ')"
}

$manifest = [ordered]@{
    releaseVersion  = $ReleaseVersion
    downloadBaseUrl = $DownloadBaseUrl
    tools           = $tools
}

ConvertTo-Json $manifest -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Wrote $($tools.Count) entries to $OutputPath"
