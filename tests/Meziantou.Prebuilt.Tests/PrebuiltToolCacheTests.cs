namespace Meziantou.Prebuilt.Tests;

public sealed class PrebuiltToolCacheTests
{
    private static readonly byte[] FfmpegContent = TestManifest.Content("ffmpeg binary content");

    private static PrebuiltToolAsset CreateAsset(byte[] content, string runtimeIdentifier = "linux-x64", string version = "9.0")
    {
        var manifest = TestManifest.Create(("ffmpeg", runtimeIdentifier, version, content));
        return new PrebuiltTool("ffmpeg", manifest).Assets[0];
    }

    [Fact]
    public void GetPath_IsVersionedAndKeyedByChecksum()
    {
        using var directory = new TemporaryDirectory();
        var cache = new PrebuiltToolCache(directory.FullPath);
        var asset = CreateAsset(FfmpegContent);
        var rebuiltAsset = CreateAsset(TestManifest.Content("rebuilt ffmpeg binary"));

        var path = cache.GetPath(asset);

        Assert.Equal(Path.Combine(directory.FullPath, "ffmpeg", "9.0-linux-x64-" + asset.Sha256[..16], "ffmpeg"), path);
        Assert.True(Path.IsPathFullyQualified(path));
        Assert.NotEqual(path, cache.GetPath(rebuiltAsset));
        Assert.NotEqual(path, cache.GetPath(CreateAsset(FfmpegContent, version: "9.1")));
        Assert.Equal("ffmpeg.exe", Path.GetFileName(cache.GetPath(CreateAsset(FfmpegContent, runtimeIdentifier: "win-x64"))));
    }

    [Fact]
    public void Constructor_UsesFullPath()
    {
        var cache = new PrebuiltToolCache("relative-cache");

        Assert.Equal(Path.GetFullPath("relative-cache"), cache.CacheDirectory);
    }

    [Fact]
    public void DefaultCacheDirectory_IsInLocalApplicationData()
    {
        var expected = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify), "Meziantou.Prebuilt");

        Assert.Equal(expected, PrebuiltToolCache.DefaultCacheDirectory);
        Assert.Equal(Path.GetFullPath(expected), PrebuiltToolCache.Default.CacheDirectory);
    }

    [Fact]
    public async Task GetOrDownloadAsync_DownloadsAndValidates()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        Assert.False(cache.IsCached(asset));
        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal(cache.GetPath(asset), path);
        Assert.True(cache.IsCached(asset));
        var content = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
        Assert.Equal(FfmpegContent, content);
        Assert.Equal(new[] { path }, directory.GetFiles());
        if (!OperatingSystem.IsWindows())
        {
            Assert.True(File.GetUnixFileMode(path).HasFlag(UnixFileMode.UserExecute));
        }
    }

    [Fact]
    public async Task GetOrDownloadAsync_AlreadyCached_DoesNotDownload()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var path1 = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);
        var path2 = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal(path1, path2);
        Assert.Equal(1, handler.RequestCount);
    }

    [Fact]
    public async Task GetOrDownloadAsync_ChecksumMismatch_Throws()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler();
        var tampered = FfmpegContent.ToArray();
        tampered[0] ^= 0xFF;
        handler.Add(asset.DownloadUrl, tampered);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        await Assert.ThrowsAsync<InvalidDataException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.False(cache.IsCached(asset));
        Assert.Empty(directory.GetFiles());
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(1)]
    public async Task GetOrDownloadAsync_SizeMismatch_Throws(int delta)
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, delta < 0 ? FfmpegContent[..^1] : [.. FfmpegContent, 0]);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        await Assert.ThrowsAsync<InvalidDataException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.Empty(directory.GetFiles());
    }

    [Fact]
    public async Task GetOrDownloadAsync_HttpError_Throws()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler();
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        await Assert.ThrowsAsync<HttpRequestException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.Empty(directory.GetFiles());
    }

    [Fact]
    public async Task GetOrDownloadAsync_Concurrent_ReturnsSamePath()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        using var handler = new FakeHttpMessageHandler { Delay = TimeSpan.FromMilliseconds(100) };
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache1 = new PrebuiltToolCache(directory.FullPath, httpClient);
        var cache2 = new PrebuiltToolCache(directory.FullPath, httpClient);

        var paths = await Task.WhenAll(
            cache1.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken),
            cache2.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.Equal(paths[0], paths[1]);
        Assert.Equal(2, handler.RequestCount);
        Assert.Equal(new[] { paths[0] }, directory.GetFiles());
        var content = await File.ReadAllBytesAsync(paths[0], TestContext.Current.CancellationToken);
        Assert.Equal(FfmpegContent, content);
    }

    [Fact]
    public async Task GetOrDownloadAsync_UnsupportedRuntimeIdentifier_Throws()
    {
        using var directory = new TemporaryDirectory();
        var manifest = TestManifest.Create(("ffmpeg", "linux-x64", "9.0", FfmpegContent));
        var tool = new PrebuiltTool("ffmpeg", manifest);
        var cache = new PrebuiltToolCache(directory.FullPath);

        var exception = await Assert.ThrowsAsync<PlatformNotSupportedException>(() => cache.GetOrDownloadAsync(tool, "osx-arm64", TestContext.Current.CancellationToken));

        Assert.Contains("linux-x64", exception.Message);
    }
}
