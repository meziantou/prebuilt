namespace Meziantou.Prebuilt.Tests;

public sealed class PrebuiltManifestTests
{
    [Fact]
    public void Parse_ComputesDownloadUrl()
    {
        var manifest = TestManifest.Create(("ffmpeg", "win-x64", "9.0", TestManifest.Content("ffmpeg")));

        var entry = Assert.Single(manifest.Entries);
        Assert.Equal("1.2.3", manifest.ReleaseVersion);
        Assert.Equal("ffmpeg-win-x64.exe", entry.FileName);
        Assert.Equal(new Uri(TestManifest.DownloadBaseUrl + "ffmpeg-win-x64.exe"), entry.DownloadUrl);
    }

    [Fact]
    public void Parse_AddsTrailingSlashToDownloadBaseUrl()
    {
        var manifest = PrebuiltManifest.Parse("""
            {
              "releaseVersion": "1.0.0",
              "downloadBaseUrl": "https://example.com/download/1.0.0",
              "tools": [ { "name": "zopfli", "runtimeIdentifier": "linux-x64", "version": "1.0.3", "fileName": "zopfli-linux-x64", "size": 1, "sha256": "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789" } ]
            }
            """);

        var entry = Assert.Single(manifest.Entries);
        Assert.Equal(new Uri("https://example.com/download/1.0.0/zopfli-linux-x64"), entry.DownloadUrl);
        Assert.Equal("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", entry.Sha256);
    }

    [Theory]
    [InlineData("""{ "downloadBaseUrl": "https://example.com/", "tools": [] }""")]
    [InlineData("""{ "releaseVersion": "1.0.0", "tools": [] }""")]
    [InlineData("""{ "releaseVersion": "1.0.0", "downloadBaseUrl": "relative/", "tools": [] }""")]
    [InlineData("""{ "releaseVersion": "1.0.0", "downloadBaseUrl": "https://example.com/", "tools": [ { "name": "zopfli", "runtimeIdentifier": "linux-x64", "version": "1.0.3", "fileName": "zopfli-linux-x64", "size": 1, "sha256": "not-a-sha" } ] }""")]
    [InlineData("""{ "releaseVersion": "1.0.0", "downloadBaseUrl": "https://example.com/", "tools": [ { "runtimeIdentifier": "linux-x64", "version": "1.0.3", "fileName": "zopfli-linux-x64", "size": 1, "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" } ] }""")]
    public void Parse_InvalidManifest_Throws(string json)
    {
        Assert.Throws<InvalidDataException>(() => PrebuiltManifest.Parse(json));
    }
}
