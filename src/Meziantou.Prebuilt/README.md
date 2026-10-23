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

Tools: `Zopfli`, `Oxipng`, `Pngout`, `Ffmpeg`, `Ffprobe`, `X265`, `Kvazaar`, `Cwebp`, `Dwebp`, `Webpmux`, `WebpAnimDump`, `Avifenc`, `Avifdec`, `Cjxl`, `Djxl`, `Jxlinfo`, `JxlFromTree`, `JxlOxide`, `HbShape`, `HbInfo`, `HbSubset`, `HbVector`, `HbRaster`, `Woff2Compress`, `Woff2Decompress`, `Woff2Info`, `OpjCompress`, `OpjDecompress`, `OpjDump`, `OjphCompress`, `OjphExpand`, `IsoJpeg`, `Dec265`, `HeifEnc`, `HeifDec`, `HeifInfo`, `HmEncoder`, `HmDecoder`, `Qpdf`, `Mutool`, `Pdftoppm`, `Pdftotext`, `Pdffonts`, `Pdfinfo`, `Pdfsig`, `ArlingtonTestGrammar`, `VeraPdf`, `PdfiumTest`. Not every tool is available for every runtime identifier; use `tool.IsSupported()` or `tool.Assets` to check.

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

## Tools with their files

Some tools need more than their executable: `VeraPdf` comes with a Java runtime, `ArlingtonTestGrammar` with the TSV files of the Arlington PDF Model, and `PdfiumTest` with the fonts of the PDFium pixel tests. Their release file is a `.tar.gz` archive (`PrebuiltToolAsset.IsArchive`), with the executable at its root. `GetOrDownloadAsync` extracts it and still returns the path of the executable; the other files are in the same folder:

```csharp
string testGrammar = await PrebuiltTools.ArlingtonTestGrammar.GetOrDownloadAsync();
string tsv = Path.Combine(Path.GetDirectoryName(testGrammar)!, "tsv", "latest");

// TestGrammar --tsvdir <tsv> --pdf file.pdf: the problems are the "Error:" lines, the exit code is 0
using var process = Process.Start(testGrammar, ["--no-color", "--tsvdir", tsv, "--pdf", "file.pdf"]);
await process.WaitForExitAsync();
```

- `ArlingtonTestGrammar` is built from a commit of the master branch of [pdf-association/arlington-pdf-model](https://github.com/pdf-association/arlington-pdf-model), whose last release is from 2021: its version is the version of TestGrammar followed by the commit (`0.81+d148fee`). The archive has the TSV files of every PDF version (`tsv/1.0` to `tsv/2.0`, and `tsv/latest`).
- `VeraPdf` runs veraPDF with the Java runtime of the archive. The Linux runtimes need glibc. veraPDF writes its configuration to a `config` folder next to the executable the first time it runs, so the cache folder must be writable. It exits with 0 when every file is compliant and with 1 otherwise.

- `PdfiumTest` is configured as the PDFium pixel tests are run, so that its rasters can be compared with the PDFium expectations. Its folder has `test_fonts/` (`third_party/test_fonts`) and `fonts/` (`testing/resources/fonts`): the pixel tests run `pdfium_test --send-events --png --md5 --time=1399672130 --font-dir=<folder>/test_fonts --croscore-font-names <file>.pdf`, or `--font-dir=<folder>/fonts/ahem` and `fonts/symbolneu` for the tests whose folder names say `use_ahem` or `use_symbolneu`. Its version is the N of the PDFium `chromium/N` branch it is built from. The Linux builds need glibc and libgcc_s.

## Cache

The default cache folder is `Meziantou.Prebuilt` in the local application data folder (`%LOCALAPPDATA%` on Windows, `~/.local/share` on Linux, `~/Library/Application Support` on macOS). Files are stored at:

```
<cache>/<tool>/<version>-<rid>-<first 16 chars of the SHA-256>/<tool>[.exe]
```

Versions and builds never collide, and identical files are shared between package versions. A file is downloaded to a temporary file next to its final path, verified, made executable, and then moved into place. An archive is verified, extracted to a temporary folder, and that folder is then moved into place: the executable exists only once every file of the archive does. Concurrent calls for the same file within a process share a single download; concurrent downloads from several processes are also safe.
