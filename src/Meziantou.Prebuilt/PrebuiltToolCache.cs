using System.Buffers;
using System.Security.Cryptography;

namespace Meziantou.Prebuilt;

/// <summary>Downloads tools to a local folder and reuses them on the next calls.</summary>
/// <remarks>
/// Each file is stored at <c>&lt;CacheDirectory&gt;/&lt;tool&gt;/&lt;version&gt;-&lt;rid&gt;-&lt;sha256 prefix&gt;/&lt;executable&gt;</c>,
/// so different versions or builds never collide. A file is downloaded to a temporary file in the same folder,
/// checked against the expected size and SHA-256, and only then moved to its final path.
/// </remarks>
public sealed class PrebuiltToolCache
{
    private const int BufferSize = 81920;

    private static readonly HttpClient SharedHttpClient = new();

    private readonly HttpClient _httpClient;

    /// <summary>Initializes a new instance of the <see cref="PrebuiltToolCache"/> class.</summary>
    /// <param name="cacheDirectory">The folder to store the tools in. Defaults to <see cref="DefaultCacheDirectory"/>.</param>
    /// <param name="httpClient">The client used to download the tools. Defaults to a shared instance.</param>
    public PrebuiltToolCache(string? cacheDirectory = null, HttpClient? httpClient = null)
    {
        CacheDirectory = Path.GetFullPath(cacheDirectory ?? DefaultCacheDirectory);
        _httpClient = httpClient ?? SharedHttpClient;
    }

    // Declared before Default: static initializers run in textual order
    /// <summary>Gets the default cache folder: <c>Meziantou.Prebuilt</c> in the local application data folder.</summary>
    public static string DefaultCacheDirectory { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify), "Meziantou.Prebuilt");

    /// <summary>Gets a cache stored in <see cref="DefaultCacheDirectory"/>.</summary>
    public static PrebuiltToolCache Default { get; } = new();

    /// <summary>Gets the full path of the cache folder.</summary>
    public string CacheDirectory { get; }

    /// <summary>Gets the full path where the file is stored once downloaded. The file may not exist.</summary>
    public string GetPath(PrebuiltToolAsset asset)
    {
        ArgumentNullException.ThrowIfNull(asset);

        var folderName = asset.Version + "-" + asset.RuntimeIdentifier + "-" + asset.Sha256[..16];
        return Path.Combine(CacheDirectory, asset.Tool.Name, folderName, asset.ExecutableName);
    }

    /// <summary>Indicates whether the file is already downloaded.</summary>
    public bool IsCached(PrebuiltToolAsset asset) => File.Exists(GetPath(asset));

    /// <summary>Downloads the tool for a runtime identifier, unless it is already in the cache.</summary>
    /// <param name="tool">The tool.</param>
    /// <param name="runtimeIdentifier">The runtime identifier (e.g. <c>linux-x64</c>). Defaults to <see cref="PrebuiltTools.CurrentRuntimeIdentifier"/>.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The full path of the executable.</returns>
    /// <exception cref="PlatformNotSupportedException">The tool is not available for the runtime identifier.</exception>
    /// <remarks>On <c>win-arm64</c>, the <c>win-x64</c> file is downloaded when the tool is not built for <c>win-arm64</c>.</remarks>
    public Task<string> GetOrDownloadAsync(PrebuiltTool tool, string? runtimeIdentifier = null, CancellationToken cancellationToken = default)
        => GetOrDownloadAsync(tool, runtimeIdentifier, allowEmulation: true, cancellationToken);

    /// <summary>Downloads the tool for a runtime identifier, unless it is already in the cache.</summary>
    /// <param name="tool">The tool.</param>
    /// <param name="runtimeIdentifier">The runtime identifier (e.g. <c>linux-x64</c>). Defaults to <see cref="PrebuiltTools.CurrentRuntimeIdentifier"/>.</param>
    /// <param name="allowEmulation">On <c>win-arm64</c>, whether to download the <c>win-x64</c> file when the tool is not built for <c>win-arm64</c>.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The full path of the executable.</returns>
    /// <exception cref="PlatformNotSupportedException">The tool is not available for the runtime identifier.</exception>
    public Task<string> GetOrDownloadAsync(PrebuiltTool tool, string? runtimeIdentifier, bool allowEmulation, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(tool);

        var asset = tool.GetAsset(runtimeIdentifier, allowEmulation);
        if (asset is null)
        {
            var rid = runtimeIdentifier ?? PrebuiltTools.CurrentRuntimeIdentifier ?? "the current platform";
            throw new PlatformNotSupportedException($"The tool '{tool.Name}' is not available for {rid}. Available runtime identifiers: {string.Join(", ", tool.Assets.Select(a => a.RuntimeIdentifier))}.");
        }

        return GetOrDownloadAsync(asset, cancellationToken);
    }

    /// <summary>Downloads the file, unless it is already in the cache.</summary>
    /// <returns>The full path of the executable.</returns>
    /// <exception cref="InvalidDataException">The downloaded file does not match the expected size or SHA-256.</exception>
    public async Task<string> GetOrDownloadAsync(PrebuiltToolAsset asset, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(asset);

        // A file only gets to its final path once its checksum has been validated
        var path = GetPath(asset);
        if (File.Exists(path))
            return path;

        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);

        var tempPath = Path.Combine(directory, asset.ExecutableName + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            await DownloadAsync(asset, tempPath, cancellationToken).ConfigureAwait(false);

            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(tempPath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                    UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                    UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            }

            try
            {
                File.Move(tempPath, path, overwrite: false);
            }
            catch (IOException) when (File.Exists(path))
            {
                // Another process downloaded the same file concurrently. Both files have the same checksum.
            }

            return path;
        }
        finally
        {
            TryDeleteFile(tempPath);
        }
    }

    private async Task DownloadAsync(PrebuiltToolAsset asset, string destinationPath, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync(asset.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using (source.ConfigureAwait(false))
        {
            var destination = new FileStream(destinationPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, BufferSize, FileOptions.Asynchronous);
            await using (destination.ConfigureAwait(false))
            {
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
                try
                {
                    long totalBytes = 0;
                    int bytesRead;
                    while ((bytesRead = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                    {
                        totalBytes += bytesRead;
                        if (totalBytes > asset.Size)
                            throw new InvalidDataException($"The download of '{asset.DownloadUrl}' is larger than the expected {asset.Size} bytes.");

                        hash.AppendData(buffer, 0, bytesRead);
                        await destination.WriteAsync(buffer.AsMemory(0, bytesRead), cancellationToken).ConfigureAwait(false);
                    }

                    if (totalBytes != asset.Size)
                        throw new InvalidDataException($"The download of '{asset.DownloadUrl}' has {totalBytes} bytes, expected {asset.Size} bytes.");
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }

                var actualSha256 = Convert.ToHexString(hash.GetHashAndReset());
                if (!string.Equals(actualSha256, asset.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"The SHA-256 of '{asset.DownloadUrl}' is {actualSha256}, expected {asset.Sha256}.");
            }
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
