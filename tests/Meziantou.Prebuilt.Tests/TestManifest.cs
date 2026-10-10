using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Meziantou.Prebuilt.Tests;

internal static class TestManifest
{
    public const string DownloadBaseUrl = "https://example.com/releases/download/1.2.3/";

    public static byte[] Content(string text) => Encoding.UTF8.GetBytes(text);

    public static PrebuiltManifest Create(params (string Name, string RuntimeIdentifier, string Version, byte[] Content)[] files)
    {
        var tools = files.Select(file => new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["name"] = file.Name,
            ["runtimeIdentifier"] = file.RuntimeIdentifier,
            ["version"] = file.Version,
            ["fileName"] = file.Name + "-" + file.RuntimeIdentifier + (file.RuntimeIdentifier.StartsWith("win-", StringComparison.Ordinal) ? ".exe" : ""),
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
