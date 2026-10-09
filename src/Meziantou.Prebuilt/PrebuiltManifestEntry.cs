namespace Meziantou.Prebuilt;

internal sealed record PrebuiltManifestEntry(string Name, string RuntimeIdentifier, string Version, string FileName, long Size, string Sha256, Uri DownloadUrl);
