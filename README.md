# prebuilt

Prebuilt, mostly statically linked, binaries of image and video tools for Windows, Linux, and macOS: `zopfli`, `oxipng`, `pngout`, `ffmpeg`/`ffprobe` (built from source), the libwebp tools `cwebp`, `dwebp`, `webpmux`, and `anim_dump`, and the libavif tools `avifenc` and `avifdec`.

The binaries are available from:

- [GitHub releases](https://github.com/meziantou/prebuilt/releases). Each release also contains `versions.json` (tool versions) and `prebuilt-tools.json` (every file with its tool version, size, and SHA-256).
- The [Meziantou.Prebuilt](https://www.nuget.org/packages/Meziantou.Prebuilt) NuGet package, which lists the tools and downloads them to a local cache:

  ```csharp
  string ffmpeg = await Meziantou.Prebuilt.PrebuiltTools.Ffmpeg.GetOrDownloadAsync();
  ```

  See [src/Meziantou.Prebuilt/README.md](src/Meziantou.Prebuilt/README.md) for details.
