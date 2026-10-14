# prebuilt

Prebuilt, mostly statically linked, binaries of image, video, and font tools for Windows, Linux, and macOS: `zopfli`, `oxipng`, `pngout`, `ffmpeg`/`ffprobe` (built from source), the HEVC encoders `x265` (8, 10 and 12 bits) and `kvazaar` they are linked with, the libwebp tools `cwebp`, `dwebp`, `webpmux`, and `anim_dump`, the libavif tools `avifenc` and `avifdec`, the libjxl tools `cjxl`, `djxl`, `jxlinfo`, and `jxl_from_tree`, `jxl-oxide`, the HarfBuzz tools `hb-shape`, `hb-info`, `hb-subset`, `hb-vector`, and `hb-raster` (built with FreeType), the Google woff2 tools `woff2_compress`, `woff2_decompress`, and `woff2_info`, the OpenJPEG JPEG 2000 tools `opj_compress`, `opj_decompress`, and `opj_dump` (built without libpng, libtiff, and LittleCMS), the OpenJPH HTJ2K tools `ojph_compress` and `ojph_expand`, `iso-jpeg`, the `jpeg` tool of the ISO JPEG reference codec (see [below](#iso-jpeg)), the libde265 decoder `dec265`, the libheif tools `heif-enc`, `heif-dec`, and `heif-info` (HEVC only, with x265 and libde265), and `TAppEncoder` and `TAppDecoder`, the encoder and the decoder of HM, the HEVC reference software.

The binaries are available from:

- [GitHub releases](https://github.com/meziantou/prebuilt/releases). Each release also contains `versions.json` (tool versions), `prebuilt-tools.json` (every file with its tool version, size, and SHA-256), and `build-keys.json` (the hash of what each build depends on: CI takes the binaries whose hash did not change from the latest release instead of building them again; running the workflow manually with `rebuild` builds everything).
- The [Meziantou.Prebuilt](https://www.nuget.org/packages/Meziantou.Prebuilt) NuGet package, which lists the tools and downloads them to a local cache:

  ```csharp
  string ffmpeg = await Meziantou.Prebuilt.PrebuiltTools.Ffmpeg.GetOrDownloadAsync();
  ```

  See [src/Meziantou.Prebuilt/README.md](src/Meziantou.Prebuilt/README.md) for details.

## iso-jpeg

`iso-jpeg` is the `jpeg` command-line tool of [thorfdbg/libjpeg](https://github.com/thorfdbg/libjpeg), the ISO JPEG reference codec: a JPEG (ISO/IEC 10918-1) encoder and decoder that shares no code with libjpeg-turbo, with arithmetic coding, 12-bit samples, and the progressive and hierarchical processes. `jpeg` says too little for a release file, so the files are named `iso-jpeg-<runtime identifier>` (`iso-jpeg-win-x64.exe`, `iso-jpeg-linux-x64`, ...).

- **Version**: libjpeg has no release tag, and the tool prints no version. It is built from a commit of the `master` branch, and its version is the last release of the `README.history` file at that commit followed by the commit: `1.72+702114c`.
- **License**: libjpeg is available under the GNU General Public License, version 3 or later, or under the ITU software license, which covers evaluation and conformance testing. Both texts are in its repository: [README.license.gpl](https://github.com/thorfdbg/libjpeg/blob/master/README.license.gpl) and [README.license.itu](https://github.com/thorfdbg/libjpeg/blob/master/README.license.itu). As for the other GPL tools (`ffmpeg`, `ffprobe`, `x265`), a release holds the binaries only, without the license files.
- **Exit code**: `iso-jpeg` exits with 0 when a conversion fails. It prints the error and leaves an empty output file, or does not touch it: a file that was there before the conversion can still be there. Delete the output file first, and check afterwards that it exists and is not empty, rather than the exit code. Only a command line it does not understand gives another exit code.

`iso-jpeg in.jpg out.ppm` decodes, and `iso-jpeg -q <quality> [options] in.ppm out.jpg` encodes: `-a` for arithmetic coding, `-v` for the progressive process, `-h` for optimized Huffman tables, `-z <mcus>` for a restart interval, `-s 1x1,2x2,2x2` for subsampling, `-c` for no color transformation, `-y <levels>` for the hierarchical process (with `-h`), and `-n` for a DNL marker. A PNM file whose maximum value is 4095 is encoded with 12-bit samples. Lossless encoding (`-p`) fails at this commit with "DQT marker missing".
