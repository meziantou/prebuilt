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
    public async Task GetOrDownloadAsync_Concurrent_DownloadsOnce()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttpMessageHandler { ResponseGate = gate.Task };
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache1 = new PrebuiltToolCache(directory.FullPath, httpClient);
        var cache2 = new PrebuiltToolCache(directory.FullPath, httpClient);

        var tasks = Enumerable.Range(0, 10)
            .Select(i => (i % 2 == 0 ? cache1 : cache2).GetOrDownloadAsync(asset, TestContext.Current.CancellationToken))
            .ToArray();
        gate.SetResult();
        var paths = await Task.WhenAll(tasks);

        Assert.All(paths, path => Assert.Equal(cache1.GetPath(asset), path));
        Assert.Equal(1, handler.RequestCount);
        Assert.Equal(new[] { paths[0] }, directory.GetFiles());
        var content = await File.ReadAllBytesAsync(paths[0], TestContext.Current.CancellationToken);
        Assert.Equal(FfmpegContent, content);
    }

    [Fact]
    public async Task GetOrDownloadAsync_Concurrent_CancellingOneCallerDoesNotCancelOthers()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttpMessageHandler { ResponseGate = gate.Task };
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);

        var cancelledTask = cache.GetOrDownloadAsync(asset, cts.Token);
        var task = cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelledTask);
        gate.SetResult();
        var path = await task;

        Assert.Equal(cache.GetPath(asset), path);
        Assert.Equal(1, handler.RequestCount);
        Assert.Equal(new[] { path }, directory.GetFiles());
    }

    [Fact]
    public async Task GetOrDownloadAsync_Concurrent_AllCallersCancelled_NextCallDownloadsAgain()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttpMessageHandler { ResponseGate = gate.Task };
        handler.Add(asset.DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);

        var task1 = cache.GetOrDownloadAsync(asset, cts.Token);
        var task2 = cache.GetOrDownloadAsync(asset, cts.Token);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task1);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task2);
        Assert.False(cache.IsCached(asset));

        gate.SetResult();
        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal(cache.GetPath(asset), path);
        Assert.Equal(2, handler.RequestCount);
        var content = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
        Assert.Equal(FfmpegContent, content);
    }

    [Fact]
    public async Task GetOrDownloadAsync_Concurrent_FailureIsSharedAndNextCallRetries()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(FfmpegContent);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttpMessageHandler { ResponseGate = gate.Task };
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var task1 = cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);
        var task2 = cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);
        gate.SetResult();
        await Assert.ThrowsAsync<HttpRequestException>(() => task1);
        await Assert.ThrowsAsync<HttpRequestException>(() => task2);
        Assert.Equal(1, handler.RequestCount);

        handler.Add(asset.DownloadUrl, FfmpegContent);
        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.True(cache.IsCached(asset));
        Assert.Equal(2, handler.RequestCount);
        Assert.Equal(new[] { path }, directory.GetFiles());
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

    [Fact]
    public async Task GetOrDownloadAsync_WinArm64_DownloadsWinX64()
    {
        using var directory = new TemporaryDirectory();
        var manifest = TestManifest.Create(("pngout", "win-x64", "1.0", FfmpegContent));
        var tool = new PrebuiltTool("pngout", manifest);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(tool.Assets[0].DownloadUrl, FfmpegContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var path = await cache.GetOrDownloadAsync(tool, "win-arm64", TestContext.Current.CancellationToken);
        Assert.Equal(cache.GetPath(tool.Assets[0]), path);

        await Assert.ThrowsAsync<PlatformNotSupportedException>(() => cache.GetOrDownloadAsync(tool, "win-arm64", allowEmulation: false, TestContext.Current.CancellationToken));
    }
}
