namespace Meziantou.Prebuilt;

/// <summary>A release file: one tool built for one runtime identifier.</summary>
public sealed class PrebuiltToolAsset
{
    internal PrebuiltToolAsset(PrebuiltTool tool, PrebuiltManifestEntry entry)
    {
        Tool = tool;
        RuntimeIdentifier = entry.RuntimeIdentifier;
        Version = entry.Version;
        FileName = entry.FileName;
        Size = entry.Size;
        Sha256 = entry.Sha256;
        DownloadUrl = entry.DownloadUrl;
        ExecutableName = RuntimeIdentifier.StartsWith("win-", StringComparison.OrdinalIgnoreCase) ? tool.Name + ".exe" : tool.Name;
    }

    /// <summary>Gets the tool.</summary>
    public PrebuiltTool Tool { get; }

    /// <summary>Gets the runtime identifier the file is built for (e.g. <c>linux-x64</c>).</summary>
    public string RuntimeIdentifier { get; }

    /// <summary>Gets the version of the tool.</summary>
    public string Version { get; }

    /// <summary>Gets the name of the file in the GitHub release (e.g. <c>ffmpeg-linux-x64</c>).</summary>
    public string FileName { get; }

    /// <summary>Gets the size of the file in bytes.</summary>
    public long Size { get; }

    /// <summary>Gets the SHA-256 checksum of the file, as a lowercase hexadecimal string.</summary>
    public string Sha256 { get; }

    /// <summary>Gets the download URL of the file.</summary>
    public Uri DownloadUrl { get; }

    /// <summary>Gets the name of the executable once downloaded (e.g. <c>ffmpeg.exe</c> on Windows, <c>ffmpeg</c> otherwise).</summary>
    public string ExecutableName { get; }

    /// <inheritdoc />
    public override string ToString() => FileName;
}
