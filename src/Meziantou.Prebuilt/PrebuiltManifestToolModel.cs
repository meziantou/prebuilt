namespace Meziantou.Prebuilt;

internal sealed class PrebuiltManifestToolModel
{
    public string? Name { get; set; }
    public string? RuntimeIdentifier { get; set; }
    public string? Version { get; set; }
    public string? FileName { get; set; }
    public long Size { get; set; }
    public string? Sha256 { get; set; }
}
