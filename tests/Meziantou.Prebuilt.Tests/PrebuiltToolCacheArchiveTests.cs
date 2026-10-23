namespace Meziantou.Prebuilt.Tests;

public sealed class PrebuiltToolCacheArchiveTests
{
    private const UnixFileMode Executable =
        UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
        UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute;

    private static readonly byte[] BundleContent = TestManifest.TarGz(
        ("verapdf", "#!/bin/sh\necho verapdf\n", Executable),
        ("verapdf.exe", "MZ launcher", null),
        ("lib/greenfield-apps.jar", "jar content", null),
        ("runtime/bin/java", "java", Executable));

    private static PrebuiltToolAsset CreateAsset(byte[] content, string runtimeIdentifier = "linux-x64")
    {
        var manifest = TestManifest.CreateArchives(("verapdf", runtimeIdentifier, "1.30.3", content));
        return new PrebuiltTool("verapdf", manifest).Assets[0];
    }

    [Fact]
    public void IsArchive_IsTrueForTarGzFiles()
    {
        Assert.True(CreateAsset(BundleContent).IsArchive);
        Assert.Equal("verapdf-linux-x64.tar.gz", CreateAsset(BundleContent).FileName);
        Assert.False(new PrebuiltTool("ffmpeg", TestManifest.Create(("ffmpeg", "linux-x64", "9.0", BundleContent))).Assets[0].IsArchive);
    }

    [Fact]
    public void GetPath_IsTheExecutableOfTheArchive()
    {
        using var directory = new TemporaryDirectory();
        var cache = new PrebuiltToolCache(directory.FullPath);

        var asset = CreateAsset(BundleContent);
        Assert.Equal(Path.Combine(directory.FullPath, "verapdf", "1.30.3-linux-x64-" + asset.Sha256[..16], "verapdf"), cache.GetPath(asset));
        Assert.Equal("verapdf.exe", Path.GetFileName(cache.GetPath(CreateAsset(BundleContent, "win-x64"))));
    }

    [Fact]
    public async Task GetOrDownloadAsync_ExtractsTheArchive()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, BundleContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        Assert.False(cache.IsCached(asset));
        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal(cache.GetPath(asset), path);
        Assert.True(cache.IsCached(asset));
        Assert.Equal("#!/bin/sh\necho verapdf\n", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        var bundle = Path.GetDirectoryName(path)!;
        Assert.Equal("jar content", await File.ReadAllTextAsync(Path.Combine(bundle, "lib", "greenfield-apps.jar"), TestContext.Current.CancellationToken));

        // Only the extracted files: no archive or temporary folder is left
        Assert.Equal(
            new[] { Path.Combine(bundle, "lib", "greenfield-apps.jar"), Path.Combine(bundle, "runtime", "bin", "java"), path, Path.Combine(bundle, "verapdf.exe") }.Order(StringComparer.Ordinal),
            directory.GetFiles().Order(StringComparer.Ordinal));
        Assert.Equal(new[] { bundle }, Directory.GetDirectories(Path.GetDirectoryName(bundle)!));

        if (!OperatingSystem.IsWindows())
        {
            Assert.True(File.GetUnixFileMode(path).HasFlag(UnixFileMode.UserExecute));
            Assert.True(File.GetUnixFileMode(Path.Combine(bundle, "runtime", "bin", "java")).HasFlag(UnixFileMode.UserExecute));
            Assert.False(File.GetUnixFileMode(Path.Combine(bundle, "lib", "greenfield-apps.jar")).HasFlag(UnixFileMode.UserExecute));
        }
    }

    [Fact]
    public async Task GetOrDownloadAsync_WindowsExecutableOfTheArchive()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent, "win-x64");
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, BundleContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal("verapdf.exe", Path.GetFileName(path));
        Assert.Equal("MZ launcher", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task GetOrDownloadAsync_AlreadyCached_DoesNotDownload()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, BundleContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var first = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);
        var second = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.Equal(first, second);
        Assert.Equal(1, handler.RequestCount);
    }

    [Fact]
    public async Task GetOrDownloadAsync_Concurrent_DownloadsOnce()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttpMessageHandler { ResponseGate = gate.Task };
        handler.Add(asset.DownloadUrl, BundleContent);
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
        Assert.Equal(4, directory.GetFiles().Length);
    }

    [Fact]
    public async Task GetOrDownloadAsync_FolderLeftWithoutExecutable_IsReplaced()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, BundleContent);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);
        var bundle = Path.GetDirectoryName(cache.GetPath(asset))!;
        Directory.CreateDirectory(bundle);
        await File.WriteAllTextAsync(Path.Combine(bundle, "stale.txt"), "stale", TestContext.Current.CancellationToken);

        var path = await cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken);

        Assert.True(File.Exists(path));
        Assert.False(File.Exists(Path.Combine(bundle, "stale.txt")));
    }

    [Fact]
    public async Task GetOrDownloadAsync_ChecksumMismatch_Throws()
    {
        using var directory = new TemporaryDirectory();
        var asset = CreateAsset(BundleContent);
        using var handler = new FakeHttpMessageHandler();
        var tampered = BundleContent.ToArray();
        tampered[^1] ^= 0xFF;
        handler.Add(asset.DownloadUrl, tampered);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        await Assert.ThrowsAsync<InvalidDataException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.False(cache.IsCached(asset));
        Assert.Empty(directory.GetFiles());
    }

    [Fact]
    public async Task GetOrDownloadAsync_NoExecutableAtTheRoot_Throws()
    {
        using var directory = new TemporaryDirectory();
        var content = TestManifest.TarGz(("bin/verapdf", "nested", Executable));
        var asset = CreateAsset(content);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, content);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        var exception = await Assert.ThrowsAsync<InvalidDataException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.Contains("has no 'verapdf' at its root", exception.Message, StringComparison.Ordinal);
        Assert.False(cache.IsCached(asset));
        Assert.Empty(directory.GetFiles());
    }

    [Fact]
    public async Task GetOrDownloadAsync_EntryOutsideOfTheFolder_Throws()
    {
        using var directory = new TemporaryDirectory();
        var content = TestManifest.TarGz(("verapdf", "launcher", Executable), ("../escaped.txt", "escaped", null));
        var asset = CreateAsset(content);
        using var handler = new FakeHttpMessageHandler();
        handler.Add(asset.DownloadUrl, content);
        using var httpClient = new HttpClient(handler);
        var cache = new PrebuiltToolCache(directory.FullPath, httpClient);

        await Assert.ThrowsAnyAsync<IOException>(() => cache.GetOrDownloadAsync(asset, TestContext.Current.CancellationToken));

        Assert.False(cache.IsCached(asset));
        Assert.Empty(directory.GetFiles());
    }
}
