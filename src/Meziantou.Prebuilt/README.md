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

Tools: `Zopfli`, `Oxipng`, `Pngout`, `Ffmpeg`, `Ffprobe`, `X265`, `Kvazaar`, `Cwebp`, `Dwebp`, `Webpmux`, `WebpAnimDump`, `Avifenc`, `Avifdec`, `Cjxl`, `Djxl`, `Jxlinfo`, `JxlFromTree`, `JxlOxide`, `HbShape`, `HbInfo`, `HbSubset`, `HbVector`, `HbRaster`, `Woff2Compress`, `Woff2Decompress`, `Woff2Info`, `OpjCompress`, `OpjDecompress`, `OpjDump`, `OjphCompress`, `OjphExpand`, `ExrHeader`, `ExrInfo`, `ExrMakeTiled`, `ExrMetrics`, `ExrStdAttr`, `ExrCheck`, `ExrMultiPart`, `ExrMultiView`, `ExrEnvMap`, `ExrMakePreview`, `ExrManifest`, `Exr2Aces`, `ExrFromRaw`, `ExrToRaw`, `IsoJpeg`, `Dec265`, `HeifEnc`, `HeifDec`, `HeifInfo`, `HmEncoder`, `HmDecoder`, `Qpdf`, `Mutool`, `Pdftoppm`, `Pdftotext`, `Pdffonts`, `Pdfinfo`, `Pdfsig`, `ArlingtonTestGrammar`, `VeraPdf`, `PdfiumTest`, `Zint`, `ZXingReader`, `ZBarImg`. Not every tool is available for every runtime identifier; use `tool.IsSupported()` or `tool.Assets` to check.

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

## OpenEXR

`ExrHeader`, `ExrInfo`, `ExrMakeTiled`, `ExrMetrics`, `ExrStdAttr`, `ExrCheck`, `ExrMultiPart`, `ExrMultiView`, `ExrEnvMap`, `ExrMakePreview`, `ExrManifest` and `Exr2Aces` are the utilities of the [OpenEXR](https://github.com/AcademySoftwareFoundation/openexr) release, built from its source tarball with the libdeflate, zstd and OpenJPH it comes with, and the Imath it pins. `ExrFromRaw` (`exr-from-raw`) and `ExrToRaw` (`exr-to-raw`) are two programs of this repository, built with the same OpenEXR: the first writes an EXR file from raw samples and a JSON description of its header, the second dumps the header of an EXR file as JSON and its decoded samples as raw files, bit for bit. The JSON that `exr-to-raw` writes is a description `exr-from-raw` reads, and `exr-from-raw` writes the same file again from it.

```csharp
string fromRaw = await PrebuiltTools.ExrFromRaw.GetOrDownloadAsync();
string toRaw = await PrebuiltTools.ExrToRaw.GetOrDownloadAsync();

// r.raw has the 64 x 32 HALF samples of the R channel, little-endian, row by row
File.WriteAllText("image.json", """
    {"dataWindow": [0, 0, 63, 31], "compression": "PIZ",
     "channels": [{"name": "R", "pixelType": "HALF", "file": "r.raw"}]}
    """);
using (var process = Process.Start(fromRaw, ["image.json", "image.exr"]))
{
    await process.WaitForExitAsync();
}

// dump/header.json describes the header, dump/part0.channel0.raw has the decoded samples of R
using (var process = Process.Start(toRaw, ["image.exr", "dump"]))
{
    await process.WaitForExitAsync();
}
```

### Samples

A sample file has the samples of one channel, in the pixel type of the channel, without any conversion, little-endian: `HALF` is 2 bytes (the bits of the half), `FLOAT` 4 bytes (the bits of the float, NaN payloads included), `UINT` 4 bytes.

- Scan line part: the samples of the data window, row by row from its top (`yMin`) to its bottom, whatever the line order of the file. A channel with `xSampling` and `ySampling` has the samples of the pixels whose x is a multiple of `xSampling` and whose y is a multiple of `ySampling` only.
- Tiled part: the samples of every level, one level after the other, each one as a scan line part of the data window of the level. `MIPMAP_LEVELS` levels are in order; `RIPMAP_LEVELS` levels are (0, 0), (1, 0) ... (nx-1, 0), (0, 1) ...
- Deep part: the sample count file has the number of samples of each pixel, as `UINT`, in the same order; the file of a channel has the samples of the first pixel, then those of the second pixel...

### exr-from-raw

`exr-from-raw <description.json> <output.exr>` writes `output.exr`. It exits with 0 when the file is written, 1 when OpenEXR refuses the header or the samples, and 2 when the command line or the description is invalid; it deletes the output file when it fails. The description is an object with `parts`, an array of parts, or a part itself for a single-part file; a file with more than one part is a multi-part file. A part is an object with:

| Member | Value |
| --- | --- |
| `type` | `scanlineimage` (default), `tiledimage` (default when `tiles` is given), `deepscanline` or `deeptile` |
| `name` | optional; required for every part of a multi-part file |
| `dataWindow` | `[xMin, yMin, xMax, yMax]`, required |
| `displayWindow` | `[xMin, yMin, xMax, yMax]`, the data window by default |
| `compression` | `NONE`, `RLE`, `ZIPS`, `ZIP` (default), `PIZ`, `PXR24`, `B44`, `B44A`, `DWAA`, `DWAB`, `HTJ2K256`, `HTJ2K32`, `LJ2K` or `ZSTD`; deep parts accept `NONE`, `RLE`, `ZIPS` and `ZSTD` only |
| `lineOrder` | `INCREASING_Y` (default), `DECREASING_Y` or `RANDOM_Y` (tiled parts) |
| `pixelAspectRatio` | 1 by default |
| `screenWindowCenter` | `[x, y]`, `[0, 0]` by default |
| `screenWindowWidth` | 1 by default |
| `tiles` | `{"xSize", "ySize", "levelMode", "roundingMode"}`: `levelMode` is `ONE_LEVEL` (default), `MIPMAP_LEVELS` or `RIPMAP_LEVELS`, `roundingMode` `ROUND_DOWN` (default) or `ROUND_UP` |
| `zipCompressionLevel`, `dwaCompressionLevel`, `zstdCompressionLevel` | optional settings of the encoder, not stored in the file (OpenEXR uses 4, 45 and 5 by default) |
| `channels` | `[{"name", "pixelType", "xSampling", "ySampling", "pLinear", "file"}]`: `pixelType` is `HALF` (default), `FLOAT` or `UINT`, the sampling 1 by default, `pLinear` false by default, and `file` the sample file; without `file`, the samples are zeros |
| `sampleCounts` | deep parts: the sample count file; without it, every pixel has no sample |
| `attributes` | `[{"name", "type", "value"}]` or `[{"name", "type", "data"}]`: any other attribute |

- The paths of the sample files are relative to the folder of the description, and their size must be the size the header gives them.
- An attribute with a `value` is of a type `exr-from-raw` knows: `box2i` and `box2f` (`[xMin, yMin, xMax, yMax]`), `chromaticities` (`[redX, redY, greenX, greenY, blueX, blueY, whiteX, whiteY]`), `compression`, `lineOrder`, `envmap` (`LATLONG`, `CUBE`) and `deepImageState` (`MESSY`, `SORTED`, `NON_OVERLAPPING`, `TIDY`) by name, `double`, `float`, `int`, `floatvector`, `keycode` (`[filmMfcCode, filmType, prefix, count, perfOffset, perfsPerFrame, perfsPerCount]`), `m33f`, `m33d`, `m44f` and `m44d` (the values row by row), `preview` (`{"width", "height", "pixels"}`, the RGBA bytes in hexadecimal), `rational` (`[numerator, denominator]`), `string`, `stringvector`, `tiledesc` (as `tiles`), `timecode` (`[timeAndFlags, userData]`), `v2i`, `v2f`, `v2d`, `v3i`, `v3f` and `v3d`. A float or double can be `"NaN"`, `"Infinity"` or `"-Infinity"`. With `data`, the bytes of the value in hexadecimal, an attribute can be of any type, and its bytes are written as they are, even when they are not a valid value of its type: OpenEXR then refuses to read the file.
- The members of a part (`channels`, `compression`, `dataWindow`, `displayWindow`, `lineOrder`, `pixelAspectRatio`, `screenWindowCenter`, `screenWindowWidth`, `tiles`, `name`, `type`, `chunkCount`) cannot be attributes.
- A single-part file is written as OpenEXR's `OutputFile`, `TiledOutputFile`, `DeepScanLineOutputFile` and `DeepTiledOutputFile` write it, a multi-part file as `MultiPartOutputFile` does: the `type` attribute is written for the parts of a multi-part file and for deep parts only. The attributes are sorted by name, as OpenEXR writes them.
- The tiles of a `RANDOM_Y` part are written in an order shuffled with a fixed seed, the same on every run and every platform; the tiles of the other parts in the order of their line order.

### exr-to-raw

`exr-to-raw [--header-only] <input.exr> <output-directory>` writes `header.json`, and, unless `--header-only`, the sample files: `partP.channelC.raw` for channel C of part P (C is the index of the channel in `channels`, which is sorted by name, as in the file) and `partP.sampleCounts.raw` for a deep part. It exits with 0 when the file is dumped, 1 when OpenEXR cannot read it, and 2 for a usage error. It does not rebuild a damaged offset table, which OpenEXR does by default: such a file is an error.

`header.json` is the description of `exr-from-raw`, with these additions, which `exr-from-raw` ignores:

- `openexr`, the OpenEXR version; `versionField`, the version field of the file, and `flags`: `{"tiled", "longNames", "nonImage", "multiPart"}`.
- In each part: `chunkCount` when the file has it; `levels` for a tiled part, the `level` (`[lx, ly]`) and the `dataWindow` of every level, in the order of the sample files; `chunkTableOffset`, the file offset of the offset table of the part, and `chunkTable`, its entries as they are in the file (the file offset of each chunk, in the order of the table, not of the chunks in the file).
- `attributes` has the attributes of the header that are not members of the part, as they are in the file and in its order, read from the bytes of the file (the OpenEXR APIs report attributes that are not in the file: a `type` for every single-part file, a `version` for every part of a file with deep data). Each one has its `type`, its `value` when OpenEXR reads it as a value of a known type with the same bytes, and always its `data`, the bytes of the value in hexadecimal.
- Floats are written with the shortest decimal that reads back as the same value.

### What else to know

- The decoded samples of the lossy compressions (`PXR24` for `FLOAT`, `B44` and `B44A` for `HALF`, `DWAA`, `DWAB` and `LJ2K` for the `R`, `G` and `B` channels) are the same on every runtime identifier: OpenEXR is compiled with `-ffp-contract=off`, so that no multiplication and addition is fused on Arm64 only, and without the SIMD code it and OpenJPH choose at run time on x64 (the AVX and SSE2 inverse DCTs of `DWAA` and `DWAB`, the SSE to AVX-512 wavelet transforms of `LJ2K`), which round differently from the scalar code Arm64 runs. An OpenEXR library built with that SIMD code can decode samples that differ slightly from these tools on x64. `UINT` channels, and the channels the DWA and LJ2K compressions do not compress lossily, are lossless.
- A chunk that a compression does not make smaller is stored uncompressed, lossy compressions included: `DWAA` leaves random `HALF` samples as they are, and `LJ2K` small tiles.
- `exrmetrics --convert -z <compression> -o <output> <input>` writes a file again with another compression, and `--pixelmode half` or `--pixelmode float` with another pixel type.
- `exrcheck` reports some files OpenEXR reads as bad: a file with a `BY` or `RY` channel that is not subsampled 2x2, a deep tiled file whose levels do not have as many rows of tiles as columns, and a multi-part file with an image part and a deep part. `exrcheck -c`, the checks of OpenEXRCore, accepts the last one.
- `exrmultipart -combine` leaves the offset tables of the parts it combines filled with zeros (all of them on Linux, all but the first on macOS): OpenEXR rebuilds them when it reads the file, and `exr-to-raw` refuses it. Write multi-part files with `exr-from-raw`.
- OpenEXR and Imath are available under the BSD 3-Clause License, OpenJPH under the BSD 2-Clause License, libdeflate under the MIT License, and zstd under the BSD License.

## Barcode tools

`Zint` writes barcodes and their module matrix, `ZXingReader` (zxing-cpp) and `ZBarImg` (ZBar) read them back from image files:

```csharp
string zint = await PrebuiltTools.Zint.GetOrDownloadAsync();
string reader = await PrebuiltTools.ZXingReader.GetOrDownloadAsync();

// A version 2 QR Code, level M, mask 3: --dump prints its module matrix, -o writes it
using (var process = Process.Start(zint, ["-b", "58", "--vers=2", "--secure=2", "--mask=3", "-d", "Hello, World!", "--scale=4", "-o", "qr.png"]))
{
    await process.WaitForExitAsync();
}

// ZXingReader -1 qr.png prints: qr.png QR Code "Hello, World!"
using (var process = Process.Start(new ProcessStartInfo(reader, ["-1", "qr.png"]) { RedirectStandardOutput = true }))
{
    string result = await process.StandardOutput.ReadToEndAsync();
    await process.WaitForExitAsync();
}
```

- `zint --dump` prints one line per row of modules, in hexadecimal, 4 modules per digit with the first one in the high bit, in groups of 2 digits, the last group with the digits the row needs only: `FE 5B F8` is the 21 modules `111111100101101111111`.
- `ZXingReader` prints the version, error correction level and mask of a QR Code, Micro QR or rMQR symbol, and `-symbol` the module matrix it sampled. It reports UPC-A as EAN-13 unless `-formats UPC-A`, and exits with 0 when it cannot load an image.
- `ZBarImg` reads EAN/UPC (with `-Sean2.enable` and `-Sean5.enable` for the add-ons, reported as separate `EAN-2` and `EAN-5` symbols), DataBar, Code 128, Code 93, Code 39, Codabar, Interleaved 2 of 5 and QR Code, not Micro QR or rMQR. It reads PNG, BMP, GIF, PCX, PNM and TGA files, and exits with 4 when it finds no barcode. ZBar is available under the GNU Lesser General Public License, version 2.1 or later; its sources are the ZBar release of the version of the tool.

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
