# prebuilt

Prebuilt, mostly statically linked, binaries of image, video, and font tools for Windows, Linux, and macOS: `zopfli`, `oxipng`, `pngout`, `ffmpeg`/`ffprobe` (built from source), the HEVC encoders `x265` (8, 10 and 12 bits) and `kvazaar` they are linked with, the libwebp tools `cwebp`, `dwebp`, `webpmux`, and `anim_dump`, the libavif tools `avifenc` and `avifdec`, the libjxl tools `cjxl`, `djxl`, `jxlinfo`, and `jxl_from_tree`, `jxl-oxide`, the HarfBuzz tools `hb-shape`, `hb-info`, `hb-subset`, `hb-vector`, and `hb-raster` (built with FreeType), the Google woff2 tools `woff2_compress`, `woff2_decompress`, and `woff2_info`, the OpenJPEG JPEG 2000 tools `opj_compress`, `opj_decompress`, and `opj_dump` (built without libpng, libtiff, and LittleCMS), the OpenJPH HTJ2K tools `ojph_compress` and `ojph_expand`, the libde265 decoder `dec265`, the libheif tools `heif-enc`, `heif-dec`, and `heif-info` (HEVC only, with x265 and libde265), and `TAppEncoder` and `TAppDecoder`, the encoder and the decoder of HM, the HEVC reference software.

The binaries are available from:

- [GitHub releases](https://github.com/meziantou/prebuilt/releases). Each release also contains `versions.json` (tool versions) and `prebuilt-tools.json` (every file with its tool version, size, and SHA-256).
- The [Meziantou.Prebuilt](https://www.nuget.org/packages/Meziantou.Prebuilt) NuGet package, which lists the tools and downloads them to a local cache:

  ```csharp
  string ffmpeg = await Meziantou.Prebuilt.PrebuiltTools.Ffmpeg.GetOrDownloadAsync();
  ```

  See [src/Meziantou.Prebuilt/README.md](src/Meziantou.Prebuilt/README.md) for details.
