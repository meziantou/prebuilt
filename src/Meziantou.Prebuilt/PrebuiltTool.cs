namespace Meziantou.Prebuilt;

/// <summary>A tool of the release, available for one or more runtime identifiers.</summary>
public sealed class PrebuiltTool
{
    private readonly Func<PrebuiltManifest> _manifestProvider;
    private readonly Lazy<(string Version, IReadOnlyList<PrebuiltToolAsset> Assets)> _data;

    internal PrebuiltTool(string name)
        : this(name, static () => PrebuiltManifest.Embedded)
    {
    }

    internal PrebuiltTool(string name, PrebuiltManifest manifest)
        : this(name, () => manifest)
    {
    }

    private PrebuiltTool(string name, Func<PrebuiltManifest> manifestProvider)
    {
        Name = name;
        _manifestProvider = manifestProvider;
        _data = new(LoadData);
    }

    /// <summary>Gets the name of the tool, as used in the release file names (e.g. <c>ffmpeg</c>).</summary>
    public string Name { get; }

    /// <summary>Gets the version of the tool (e.g. <c>9.0</c>). It is not the release version.</summary>
    public string Version => _data.Value.Version;

    /// <summary>Gets the release files of the tool, one per runtime identifier.</summary>
    public IReadOnlyList<PrebuiltToolAsset> Assets => _data.Value.Assets;

    /// <summary>Gets the release file for a runtime identifier.</summary>
    /// <param name="runtimeIdentifier">The runtime identifier (e.g. <c>linux-x64</c>). Defaults to <see cref="PrebuiltTools.CurrentRuntimeIdentifier"/>.</param>
    /// <returns>The release file, or <see langword="null"/> when the tool is not available for this runtime identifier.</returns>
    public PrebuiltToolAsset? GetAsset(string? runtimeIdentifier = null)
    {
        runtimeIdentifier ??= PrebuiltTools.CurrentRuntimeIdentifier;
        if (runtimeIdentifier is null)
            return null;

        foreach (var asset in Assets)
        {
            if (string.Equals(asset.RuntimeIdentifier, runtimeIdentifier, StringComparison.OrdinalIgnoreCase))
                return asset;
        }

        return null;
    }

    /// <summary>Indicates whether the tool is available for a runtime identifier.</summary>
    /// <param name="runtimeIdentifier">The runtime identifier (e.g. <c>linux-x64</c>). Defaults to <see cref="PrebuiltTools.CurrentRuntimeIdentifier"/>.</param>
    public bool IsSupported(string? runtimeIdentifier = null) => GetAsset(runtimeIdentifier) is not null;

    /// <summary>Downloads the tool for the current machine to <see cref="PrebuiltToolCache.Default"/>, unless it is already there.</summary>
    /// <returns>The full path of the executable.</returns>
    public Task<string> GetOrDownloadAsync(CancellationToken cancellationToken = default)
        => PrebuiltToolCache.Default.GetOrDownloadAsync(this, runtimeIdentifier: null, cancellationToken);

    /// <inheritdoc />
    public override string ToString() => Name;

    private (string Version, IReadOnlyList<PrebuiltToolAsset> Assets) LoadData()
    {
        var manifest = _manifestProvider();
        var assets = new List<PrebuiltToolAsset>();
        foreach (var entry in manifest.Entries)
        {
            if (entry.Name == Name)
            {
                assets.Add(new PrebuiltToolAsset(this, entry));
            }
        }

        if (assets.Count == 0)
            throw new InvalidOperationException($"The tool '{Name}' is not part of the release {manifest.ReleaseVersion}.");

        return (assets[0].Version, assets);
    }
}
