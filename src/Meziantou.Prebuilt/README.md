# Meziantou.Prebuilt

Lists the tools published by [meziantou/prebuilt](https://github.com/meziantou/prebuilt) and downloads them to a local cache.

The package version is the GitHub release version: `Meziantou.Prebuilt` 3.0.0 downloads the files of the [3.0.0 release](https://github.com/meziantou/prebuilt/releases/tag/3.0.0). The size and SHA-256 of every file is embedded in the package and checked after each download.

```csharp
using Meziantou.Prebuilt;

// Download ffmpeg for the current OS/architecture (or reuse the cached copy) and get its full path
string ffmpeg = await PrebuiltTools.Ffmpeg.GetOrDownloadAsync();

// List the tools, their version and checksum
foreach (var tool in PrebuiltTools.All)
{
    foreach (var asset in tool.Assets)
    {
        Console.WriteLine($"{tool.Name} {tool.Version} {asset.RuntimeIdentifier} {asset.Sha256} {asset.DownloadUrl}");
    }
}

// Use another cache folder or HttpClient, or another runtime identifier
var cache = new PrebuiltToolCache(cacheDirectory: "/tmp/tools", httpClient: myHttpClient);
string cwebp = await cache.GetOrDownloadAsync(PrebuiltTools.Cwebp, runtimeIdentifier: "linux-arm64");
```

Tools: `Zopfli`, `Oxipng`, `Pngout`, `Ffmpeg`, `Ffprobe`, `Cwebp`, `Dwebp`, `Webpmux`, `WebpAnimDump`. Not every tool is available for every runtime identifier; use `tool.IsSupported()` or `tool.Assets` to check.

On `win-arm64`, a tool that is not built for Arm64 (e.g. `pngout`) falls back to its `win-x64` build, which Windows on Arm runs through emulation. Pass `allowEmulation: false` to `GetAsset`, `IsSupported` or `GetOrDownloadAsync` to only get native builds:

```csharp
string pngout = await PrebuiltTools.Pngout.GetOrDownloadAsync(allowEmulation: false); // throws PlatformNotSupportedException on win-arm64
```

## Cache

The default cache folder is `Meziantou.Prebuilt` in the local application data folder (`%LOCALAPPDATA%` on Windows, `~/.local/share` on Linux, `~/Library/Application Support` on macOS). Files are stored at:

```
<cache>/<tool>/<version>-<rid>-<first 16 chars of the SHA-256>/<tool>[.exe]
```

Versions and builds never collide, and identical files are shared between package versions. A file is downloaded to a temporary file next to its final path, verified, made executable, and then moved into place. Concurrent downloads, including from several processes, are safe.
