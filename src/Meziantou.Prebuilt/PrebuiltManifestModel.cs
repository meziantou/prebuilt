namespace Meziantou.Prebuilt;

internal sealed class PrebuiltManifestModel
{
    public string? ReleaseVersion { get; set; }
    public string? DownloadBaseUrl { get; set; }
    public List<PrebuiltManifestToolModel>? Tools { get; set; }
}
