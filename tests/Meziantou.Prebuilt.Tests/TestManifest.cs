using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Meziantou.Prebuilt.Tests;

internal static class TestManifest
{
    public const string DownloadBaseUrl = "https://example.com/releases/download/1.2.3/";

    public static byte[] Content(string text) => Encoding.UTF8.GetBytes(text);

    public static PrebuiltManifest Create(params (string Name, string RuntimeIdentifier, string Version, byte[] Content)[] files)
        => Create(archive: false, files);

    /// <summary>A manifest whose files are <c>.tar.gz</c> archives.</summary>
    public static PrebuiltManifest CreateArchives(params (string Name, string RuntimeIdentifier, string Version, byte[] Content)[] files)
        => Create(archive: true, files);

    /// <summary>A <c>.tar.gz</c> archive with the given files; a <see langword="null"/> mode is 644.</summary>
    public static byte[] TarGz(params (string Path, string Content, UnixFileMode? Mode)[] entries)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
        using (var writer = new TarWriter(gzip, TarEntryFormat.Pax, leaveOpen: true))
        {
            foreach (var entry in entries)
            {
                var tarEntry = new PaxTarEntry(TarEntryType.RegularFile, entry.Path)
                {
                    Mode = entry.Mode ?? (UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead),
                    DataStream = new MemoryStream(Encoding.UTF8.GetBytes(entry.Content)),
                };
                writer.WriteEntry(tarEntry);
            }
        }

        return output.ToArray();
    }

    private static PrebuiltManifest Create(bool archive, (string Name, string RuntimeIdentifier, string Version, byte[] Content)[] files)
    {
        var tools = files.Select(file => new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["name"] = file.Name,
            ["runtimeIdentifier"] = file.RuntimeIdentifier,
            ["version"] = file.Version,
            ["fileName"] = file.Name + "-" + file.RuntimeIdentifier + (archive ? ".tar.gz" : file.RuntimeIdentifier.StartsWith("win-", StringComparison.Ordinal) ? ".exe" : ""),
            ["size"] = file.Content.LongLength,
            ["sha256"] = Sha256(file.Content),
        });

        var json = JsonSerializer.Serialize(new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["releaseVersion"] = "1.2.3",
            ["downloadBaseUrl"] = DownloadBaseUrl,
            ["tools"] = tools.ToArray(),
        });

        return PrebuiltManifest.Parse(json);
    }

    public static string Sha256(byte[] content) => Convert.ToHexStringLower(SHA256.HashData(content));
}
