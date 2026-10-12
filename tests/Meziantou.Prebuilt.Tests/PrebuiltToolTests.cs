namespace Meziantou.Prebuilt.Tests;

public sealed class PrebuiltToolTests
{
    [Fact]
    public void CurrentRuntimeIdentifier_IsSupportedPlatform()
    {
        Assert.Contains(PrebuiltTools.CurrentRuntimeIdentifier, new[] { "win-x64", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64" });
    }

    [Fact]
    public void Tool_ExposesVersionAndAssets()
    {
        var manifest = TestManifest.Create(
            ("ffmpeg", "linux-x64", "9.0", TestManifest.Content("linux")),
            ("ffmpeg", "win-x64", "9.0", TestManifest.Content("windows")),
            ("ffprobe", "linux-x64", "9.0", TestManifest.Content("ffprobe")));
        var tool = new PrebuiltTool("ffmpeg", manifest);

        Assert.Equal("9.0", tool.Version);
        Assert.Equal(["linux-x64", "win-x64"], tool.Assets.Select(asset => asset.RuntimeIdentifier));

        var windows = tool.GetAsset("win-x64");
        Assert.NotNull(windows);
        Assert.Same(tool, windows.Tool);
        Assert.Equal("ffmpeg.exe", windows.ExecutableName);
        Assert.Equal(TestManifest.Sha256(TestManifest.Content("windows")), windows.Sha256);
        Assert.Equal(7, windows.Size);

        Assert.Equal("ffmpeg", tool.GetAsset("linux-x64")!.ExecutableName);
        Assert.True(tool.IsSupported("linux-x64"));
        Assert.False(tool.IsSupported("osx-arm64"));
        Assert.Null(tool.GetAsset("osx-arm64"));
    }

    [Fact]
    public void GetAsset_WinArm64_FallsBackToWinX64()
    {
        var manifest = TestManifest.Create(
            ("pngout", "linux-x64", "1.0", TestManifest.Content("linux")),
            ("pngout", "win-x64", "1.0", TestManifest.Content("windows")));
        var tool = new PrebuiltTool("pngout", manifest);

        Assert.Equal("win-x64", tool.GetAsset("win-arm64")?.RuntimeIdentifier);
        Assert.Equal("win-x64", tool.GetAsset("WIN-ARM64", allowEmulation: true)?.RuntimeIdentifier);
        Assert.True(tool.IsSupported("win-arm64"));

        Assert.Null(tool.GetAsset("win-arm64", allowEmulation: false));
        Assert.False(tool.IsSupported("win-arm64", allowEmulation: false));

        // Only Windows on Arm falls back
        Assert.Null(tool.GetAsset("linux-arm64"));
    }

    [Fact]
    public void GetAsset_WinArm64_PrefersNativeBuild()
    {
        var manifest = TestManifest.Create(
            ("ffmpeg", "win-x64", "9.0", TestManifest.Content("x64")),
            ("ffmpeg", "win-arm64", "9.0", TestManifest.Content("arm64")));
        var tool = new PrebuiltTool("ffmpeg", manifest);

        Assert.Equal("win-arm64", tool.GetAsset("win-arm64")?.RuntimeIdentifier);
        Assert.Equal("win-arm64", tool.GetAsset("win-arm64", allowEmulation: false)?.RuntimeIdentifier);
    }

    [Fact]
    public void Tool_NotInRelease_Throws()
    {
        var manifest = TestManifest.Create(("ffmpeg", "linux-x64", "9.0", TestManifest.Content("linux")));
        var tool = new PrebuiltTool("zopfli", manifest);

        Assert.Throws<InvalidOperationException>(() => tool.Version);
    }

    [Fact]
    public void All_ContainsEveryStaticProperty()
    {
        var properties = typeof(PrebuiltTools).GetProperties()
            .Where(property => property.PropertyType == typeof(PrebuiltTool))
            .Select(property => (PrebuiltTool)property.GetValue(obj: null)!)
            .ToList();

        Assert.Equal(properties.Count, PrebuiltTools.All.Count);
        Assert.All(properties, tool => Assert.Contains(tool, PrebuiltTools.All));
        Assert.HasCount(PrebuiltTools.All.Count, PrebuiltTools.All.Select(tool => tool.Name).Distinct(StringComparer.Ordinal));
        Assert.Equal("anim_dump", PrebuiltTools.WebpAnimDump.Name);
        Assert.Equal("avifenc", PrebuiltTools.Avifenc.Name);
        Assert.Equal("avifdec", PrebuiltTools.Avifdec.Name);
        Assert.Equal("cjxl", PrebuiltTools.Cjxl.Name);
        Assert.Equal("djxl", PrebuiltTools.Djxl.Name);
        Assert.Equal("jxlinfo", PrebuiltTools.Jxlinfo.Name);
        Assert.Equal("jxl_from_tree", PrebuiltTools.JxlFromTree.Name);
        Assert.Equal("jxl-oxide", PrebuiltTools.JxlOxide.Name);
        Assert.Equal("hb-shape", PrebuiltTools.HbShape.Name);
        Assert.Equal("hb-info", PrebuiltTools.HbInfo.Name);
        Assert.Equal("hb-subset", PrebuiltTools.HbSubset.Name);
        Assert.Equal("hb-vector", PrebuiltTools.HbVector.Name);
        Assert.Equal("hb-raster", PrebuiltTools.HbRaster.Name);
        Assert.Equal("woff2_compress", PrebuiltTools.Woff2Compress.Name);
        Assert.Equal("woff2_decompress", PrebuiltTools.Woff2Decompress.Name);
        Assert.Equal("woff2_info", PrebuiltTools.Woff2Info.Name);
        Assert.Equal("x265", PrebuiltTools.X265.Name);
        Assert.Equal("kvazaar", PrebuiltTools.Kvazaar.Name);
        Assert.Equal("dec265", PrebuiltTools.Dec265.Name);
        Assert.Equal("heif-enc", PrebuiltTools.HeifEnc.Name);
        Assert.Equal("heif-dec", PrebuiltTools.HeifDec.Name);
        Assert.Equal("heif-info", PrebuiltTools.HeifInfo.Name);
        Assert.Equal("TAppEncoder", PrebuiltTools.HmEncoder.Name);
        Assert.Equal("TAppDecoder", PrebuiltTools.HmDecoder.Name);
    }

    public static bool IsManifestEmbedded => PrebuiltManifest.IsEmbedded;

    // Runs when the tests are built with -p:PrebuiltManifestPath=<path> (CI does it with the real release manifest)
    [Fact(SkipUnless = nameof(IsManifestEmbedded), Skip = "No manifest embedded, build with -p:PrebuiltManifestPath=<path>")]
    public void EmbeddedManifest_MatchesStaticProperties()
    {

        var manifestToolNames = PrebuiltManifest.Embedded.Entries.Select(entry => entry.Name).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal);
        var propertyToolNames = PrebuiltTools.All.Select(tool => tool.Name).Order(StringComparer.Ordinal);
        Assert.Equal(propertyToolNames, manifestToolNames);

        Assert.All(PrebuiltTools.All, tool =>
        {
            Assert.NotEmpty(tool.Assets);
            Assert.NotEmpty(tool.Version);
        });
    }
}
