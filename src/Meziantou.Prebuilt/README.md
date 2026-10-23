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

Tools: `Zopfli`, `Oxipng`, `Pngout`, `Ffmpeg`, `Ffprobe`, `X265`, `Kvazaar`, `Cwebp`, `Dwebp`, `Webpmux`, `WebpAnimDump`, `Avifenc`, `Avifdec`, `Cjxl`, `Djxl`, `Jxlinfo`, `JxlFromTree`, `JxlOxide`, `HbShape`, `HbInfo`, `HbSubset`, `HbVector`, `HbRaster`, `Woff2Compress`, `Woff2Decompress`, `Woff2Info`, `OpjCompress`, `OpjDecompress`, `OpjDump`, `OjphCompress`, `OjphExpand`, `IsoJpeg`, `Dec265`, `HeifEnc`, `HeifDec`, `HeifInfo`, `HmEncoder`, `HmDecoder`, `Qpdf`, `Mutool`, `Pdftoppm`, `Pdftotext`, `Pdffonts`, `Pdfinfo`, `Pdfsig`. Not every tool is available for every runtime identifier; use `tool.IsSupported()` or `tool.Assets` to check.

On `win-arm64`, a tool that is not built for Arm64 (e.g. `pngout`) falls back to its `win-x64` build, which Windows on Arm runs through emulation. Pass `allowEmulation: false` to `GetAsset`, `IsSupported` or `GetOrDownloadAsync` to only get native builds:

```csharp
string pngout = await PrebuiltTools.Pngout.GetOrDownloadAsync(allowEmulation: false); // throws PlatformNotSupportedException on win-arm64
```

## IsoJpeg

`PrebuiltTools.IsoJpeg` is the `jpeg` command-line tool of [thorfdbg/libjpeg](https://github.com/thorfdbg/libjpeg), the ISO JPEG reference codec: a JPEG encoder and decoder that shares no code with libjpeg-turbo, with arithmetic coding, 12-bit samples, and the progressive and hierarchical processes. It is published as `iso-jpeg`, as `jpeg` says too little: the cached file is `iso-jpeg` (`iso-jpeg.exe` on Windows).

- Its version is the last release of the `README.history` file of libjpeg followed by the commit it is built from (`1.72+702114c`): libjpeg has no release tag, and the tool prints no version.
- libjpeg is available under the GNU General Public License, version 3 or later, or under the ITU software license, which covers evaluation and conformance testing. See [README.license.gpl](https://github.com/thorfdbg/libjpeg/blob/master/README.license.gpl) and [README.license.itu](https://github.com/thorfdbg/libjpeg/blob/master/README.license.itu).
- It exits with 0 when a conversion fails: it prints the error and leaves an empty output file, or does not touch it, so a file that was there before the conversion can still be there. Delete the output file first, and check it afterwards, not the exit code:

```csharp
string isoJpeg = await PrebuiltTools.IsoJpeg.GetOrDownloadAsync();

// iso-jpeg -q 85 -a input.ppm output.jpg encodes with arithmetic coding; iso-jpeg input.jpg output.ppm decodes
File.Delete("output.jpg");
using var process = Process.Start(isoJpeg, ["-q", "85", "-a", "input.ppm", "output.jpg"]);
await process.WaitForExitAsync();
if (process.ExitCode != 0 || !File.Exists("output.jpg") || new FileInfo("output.jpg").Length == 0)
{
    throw new InvalidOperationException("iso-jpeg failed");
}
```

## Cache

The default cache folder is `Meziantou.Prebuilt` in the local application data folder (`%LOCALAPPDATA%` on Windows, `~/.local/share` on Linux, `~/Library/Application Support` on macOS). Files are stored at:

```
<cache>/<tool>/<version>-<rid>-<first 16 chars of the SHA-256>/<tool>[.exe]
```

Versions and builds never collide, and identical files are shared between package versions. A file is downloaded to a temporary file next to its final path, verified, made executable, and then moved into place. Concurrent calls for the same file within a process share a single download; concurrent downloads from several processes are also safe.
