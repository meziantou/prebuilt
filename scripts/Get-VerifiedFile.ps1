<#
.SYNOPSIS
Downloads a file whose content is pinned by SHA-256.

.DESCRIPTION
    ./scripts/Get-VerifiedFile.ps1 -OutFile downloads/tool.zip -Sha256 <hash> -Uri <origin>, <mirror>

The pngout hosts sit behind bot protection that intermittently answers a runner
with something that is not the file, on every request for a minute or more, so
retrying the same host from the same runner is not enough. This script:

- returns immediately when -OutFile already has the pinned content, so the
  caller can restore it from actions/cache and skip the network entirely;
- otherwise tries every URL in order (origin first, then mirrors), retrying
  the whole list with a jittered backoff;
- reports the status, headers and start of the body of every rejected
  response, so a block can be diagnosed from the job log.

The hash pin is what makes the cache and the mirrors safe to use: the content
is verified wherever it comes from, and nothing else is ever left in -OutFile.
#>
[CmdletBinding()]
param(
    # URLs serving the same file, in order of preference.
    [Parameter(Mandatory = $true)]
    [string[]]$Uri,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{64}$")]
    [string]$Sha256,

    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# .NET APIs resolve relative paths against the process directory, not $PWD.
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# The response is untrusted and ends up in the job log: keep it on one line of
# printable ASCII so it cannot forge log lines or workflow commands.
function Format-LogText([string]$Text, [int]$MaxLength) {
    $Text = ($Text -replace "[^\x20-\x7E]+", " ").Trim()
    if ($Text.Length -gt $MaxLength) {
        $Text = $Text.Substring(0, $MaxLength) + "..."
    }
    $Text
}

function Get-RejectedResponseDescription($Response, [string]$Path) {
    $headers = foreach ($header in $Response.Headers.GetEnumerator()) {
        "$($header.Key): $($header.Value -join ', ')"
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new(512)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $length = $stream.Length
    } finally {
        $stream.Dispose()
    }
    $body = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)

    "HTTP $([int]$Response.StatusCode), $length bytes" +
        " | headers: $(Format-LogText ($headers -join '; ') 1500)" +
        " | body starts with: $(Format-LogText $body 400)"
}

$Sha256 = $Sha256.ToLowerInvariant()

if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
    $actualHash = Get-Sha256 $OutFile
    if ($actualHash -eq $Sha256) {
        Write-Host "$OutFile already has the expected content, nothing to download"
        return
    }

    Write-Warning "$OutFile has an unexpected SHA-256 ($actualHash), downloading it again"
    Remove-Item -LiteralPath $OutFile -Force
}

$null = New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    foreach ($candidate in $Uri) {
        try {
            # -SkipHttpErrorCheck: an error status is reported like any other
            # response that does not have the expected content.
            $response = Invoke-WebRequest -Uri $candidate -OutFile $OutFile -PassThru -SkipHttpErrorCheck `
                -ConnectionTimeoutSeconds 30 -OperationTimeoutSeconds 60
            $actualHash = Get-Sha256 $OutFile
            if ($actualHash -eq $Sha256) {
                Write-Host "Downloaded $OutFile from $candidate"
                return
            }

            Write-Warning ("Attempt $attempt/${MaxAttempts}: $candidate returned an unexpected SHA-256 ($actualHash): " +
                (Get-RejectedResponseDescription $response $OutFile))
        } catch {
            Write-Warning "Attempt $attempt/${MaxAttempts}: $candidate failed: $(Format-LogText "$_" 400)"
        }

        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Seconds (5 * $attempt + (Get-Random -Minimum 0 -Maximum 6))
    }
}

throw "Failed to download a file matching SHA-256 $Sha256 to $OutFile after $MaxAttempts attempts"
