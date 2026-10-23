using System.Runtime.InteropServices;

namespace Meziantou.Prebuilt;

/// <summary>The tools published in the meziantou/prebuilt GitHub release matching this package version.</summary>
public static class PrebuiltTools
{
    /// <summary>Gets the GitHub release the tools come from. It is also the version of this package.</summary>
    public static string ReleaseVersion => PrebuiltManifest.Embedded.ReleaseVersion;

    /// <summary>Gets the runtime identifier of the current machine (<c>win-x64</c>, <c>linux-arm64</c>, <c>osx-arm64</c>, ...), or <see langword="null"/> when the platform is not supported.</summary>
    public static string? CurrentRuntimeIdentifier { get; } = GetCurrentRuntimeIdentifier();

    /// <summary>zopfli, the Zopfli compression tool.</summary>
    public static PrebuiltTool Zopfli { get; } = new("zopfli");

    /// <summary>oxipng, the lossless PNG optimizer.</summary>
    public static PrebuiltTool Oxipng { get; } = new("oxipng");

    /// <summary>pngout, Ken Silverman's PNG optimizer.</summary>
    public static PrebuiltTool Pngout { get; } = new("pngout");

    /// <summary>ffmpeg, statically linked with a pinned codec set.</summary>
    public static PrebuiltTool Ffmpeg { get; } = new("ffmpeg");

    /// <summary>ffprobe, statically linked with a pinned codec set.</summary>
    public static PrebuiltTool Ffprobe { get; } = new("ffprobe");

    /// <summary>x265, the HEVC encoder, built for 8, 10 and 12 bits. It is the libx265 ffmpeg and heif-enc are linked with.</summary>
    public static PrebuiltTool X265 { get; } = new("x265");

    /// <summary>kvazaar, the HEVC encoder that writes tiles and dependent slice segments, built for 8 bits. It is the libkvazaar ffmpeg is linked with.</summary>
    public static PrebuiltTool Kvazaar { get; } = new("kvazaar");

    /// <summary>cwebp, the libwebp encoder.</summary>
    public static PrebuiltTool Cwebp { get; } = new("cwebp");

    /// <summary>dwebp, the libwebp decoder.</summary>
    public static PrebuiltTool Dwebp { get; } = new("dwebp");

    /// <summary>webpmux, the libwebp muxing tool.</summary>
    public static PrebuiltTool Webpmux { get; } = new("webpmux");

    /// <summary>anim_dump, the libwebp tool that dumps the frames of an animated image.</summary>
    public static PrebuiltTool WebpAnimDump { get; } = new("anim_dump");

    /// <summary>avifenc, the libavif encoder, statically linked with libaom.</summary>
    public static PrebuiltTool Avifenc { get; } = new("avifenc");

    /// <summary>avifdec, the libavif decoder, statically linked with dav1d.</summary>
    public static PrebuiltTool Avifdec { get; } = new("avifdec");

    /// <summary>cjxl, the libjxl encoder.</summary>
    public static PrebuiltTool Cjxl { get; } = new("cjxl");

    /// <summary>djxl, the libjxl decoder.</summary>
    public static PrebuiltTool Djxl { get; } = new("djxl");

    /// <summary>jxlinfo, the libjxl tool that describes a JPEG XL file.</summary>
    public static PrebuiltTool Jxlinfo { get; } = new("jxlinfo");

    /// <summary>jxl_from_tree, the libjxl developer tool that writes a JPEG XL file from the textual description of a modular tree.</summary>
    public static PrebuiltTool JxlFromTree { get; } = new("jxl_from_tree");

    /// <summary>jxl-oxide, a JPEG XL decoder that does not share any code with libjxl.</summary>
    public static PrebuiltTool JxlOxide { get; } = new("jxl-oxide");

    /// <summary>hb-shape, the HarfBuzz text shaper, statically linked with FreeType.</summary>
    public static PrebuiltTool HbShape { get; } = new("hb-shape");

    /// <summary>hb-info, the HarfBuzz tool that describes a font file.</summary>
    public static PrebuiltTool HbInfo { get; } = new("hb-info");

    /// <summary>hb-subset, the HarfBuzz font subsetter.</summary>
    public static PrebuiltTool HbSubset { get; } = new("hb-subset");

    /// <summary>hb-vector, the HarfBuzz tool that draws shaped text as SVG or PDF outlines, statically linked with FreeType.</summary>
    public static PrebuiltTool HbVector { get; } = new("hb-vector");

    /// <summary>hb-raster, the HarfBuzz tool that renders shaped text to a PNG or PPM image, statically linked with FreeType.</summary>
    public static PrebuiltTool HbRaster { get; } = new("hb-raster");

    /// <summary>woff2_compress, the Google woff2 tool that converts a TrueType or OpenType font to WOFF2.</summary>
    public static PrebuiltTool Woff2Compress { get; } = new("woff2_compress");

    /// <summary>woff2_decompress, the Google woff2 tool that converts a WOFF2 font to TrueType or OpenType.</summary>
    public static PrebuiltTool Woff2Decompress { get; } = new("woff2_decompress");

    /// <summary>woff2_info, the Google woff2 tool that prints the header and the table directory of a WOFF2 font.</summary>
    public static PrebuiltTool Woff2Info { get; } = new("woff2_info");

    /// <summary>opj_compress, the OpenJPEG JPEG 2000 encoder, built without libpng, libtiff and LittleCMS: it reads PNM, PAM, PGX, raw, BMP and TGA files.</summary>
    public static PrebuiltTool OpjCompress { get; } = new("opj_compress");

    /// <summary>opj_decompress, the OpenJPEG JPEG 2000 decoder, which also decodes HTJ2K, built without libpng, libtiff and LittleCMS: it writes PNM, PAM, PGX, raw, BMP and TGA files, and applies no ICC profile.</summary>
    public static PrebuiltTool OpjDecompress { get; } = new("opj_decompress");

    /// <summary>opj_dump, the OpenJPEG tool that describes a JPEG 2000 codestream or file.</summary>
    public static PrebuiltTool OpjDump { get; } = new("opj_dump");

    /// <summary>ojph_compress, the OpenJPH HTJ2K (JPEG 2000 Part 15) encoder, built without libtiff: it reads PGM, PPM, PFM, yuv and raw files.</summary>
    public static PrebuiltTool OjphCompress { get; } = new("ojph_compress");

    /// <summary>ojph_expand, the OpenJPH HTJ2K (JPEG 2000 Part 15) decoder, built without libtiff: it writes PGM, PPM, PFM, yuv and raw files.</summary>
    public static PrebuiltTool OjphExpand { get; } = new("ojph_expand");

    /// <summary>iso-jpeg, the <c>jpeg</c> tool of the ISO JPEG reference codec (thorfdbg/libjpeg): a JPEG encoder and decoder that shares no code with libjpeg-turbo, with arithmetic coding, 12-bit samples, and the progressive and hierarchical processes. It exits with 0 when a conversion fails: delete the output file first, and check afterwards that it exists and is not empty.</summary>
    public static PrebuiltTool IsoJpeg { get; } = new("iso-jpeg");

    /// <summary>dec265, the libde265 HEVC decoder, built without SDL and videogfx.</summary>
    public static PrebuiltTool Dec265 { get; } = new("dec265");

    /// <summary>heif-enc, the libheif encoder, statically linked with x265 (8, 10 and 12 bits) as its only encoder.</summary>
    public static PrebuiltTool HeifEnc { get; } = new("heif-enc");

    /// <summary>heif-dec, the libheif decoder, statically linked with libde265 as its only decoder.</summary>
    public static PrebuiltTool HeifDec { get; } = new("heif-dec");

    /// <summary>heif-info, the libheif tool that describes a HEIF file.</summary>
    public static PrebuiltTool HeifInfo { get; } = new("heif-info");

    /// <summary>TAppEncoder, the encoder of HM, the HEVC reference software, built with its high bit depth support.</summary>
    public static PrebuiltTool HmEncoder { get; } = new("TAppEncoder");

    /// <summary>TAppDecoder, the decoder of HM, the HEVC reference software, built with its high bit depth support.</summary>
    public static PrebuiltTool HmDecoder { get; } = new("TAppDecoder");

    /// <summary>qpdf, the PDF structure tool (<c>--check</c>, <c>--json</c>, encryption and decryption), built with its native crypto provider only, which implements every encryption variant (RC4 40 and 128 bits, AES-128, AES-256), and statically linked with zlib and libjpeg-turbo.</summary>
    public static PrebuiltTool Qpdf { get; } = new("qpdf");

    /// <summary>mutool, the command-line tool of MuPDF (<c>draw</c>, <c>show</c>, <c>clean</c>, ...), statically linked with the third-party libraries MuPDF ships, and built with its built-in fonts, without libcrypto (no digital signatures) and without Tesseract (no OCR).</summary>
    public static PrebuiltTool Mutool { get; } = new("mutool");

    /// <summary>pdftoppm, the Poppler tool that renders pages to PPM, PGM, PBM, PNG or JPEG images, statically linked with FreeType, LittleCMS, libjpeg-turbo, OpenJPEG and libpng. It is built with the "generic" font configuration: a font a file does not embed is drawn only when the URW base 35 Type 1 fonts are in a Ghostscript font directory.</summary>
    public static PrebuiltTool Pdftoppm { get; } = new("pdftoppm");

    /// <summary>pdftotext, the Poppler tool that extracts the text of a PDF file.</summary>
    public static PrebuiltTool Pdftotext { get; } = new("pdftotext");

    /// <summary>pdffonts, the Poppler tool that lists the fonts of a PDF file, and whether they are embedded and subset.</summary>
    public static PrebuiltTool Pdffonts { get; } = new("pdffonts");

    /// <summary>pdfinfo, the Poppler tool that describes a PDF file (version, page count and sizes, encryption, metadata, ...).</summary>
    public static PrebuiltTool Pdfinfo { get; } = new("pdfinfo");

    /// <summary>pdfsig, the Poppler tool that verifies the digital signatures of a PDF file, statically linked with NSS. It is not available for <c>win-x64</c>. Without an NSS database, no certificate is trusted: <c>-nocert</c> skips the certificate check.</summary>
    public static PrebuiltTool Pdfsig { get; } = new("pdfsig");

    /// <summary>TestGrammar, the checker of the Arlington PDF Model, built with the copy of PDFium of its repository. The release file is an archive: the folder of the executable also holds <c>tsv/</c>, the TSV files of the model at the same commit (pass <c>--tsvdir &lt;folder&gt;/tsv/latest</c>). It exits with 0 whatever it finds: the problems are the <c>Error:</c> lines of its report.</summary>
    public static PrebuiltTool ArlingtonTestGrammar { get; } = new("TestGrammar");

    /// <summary>verapdf, the veraPDF PDF/A and PDF/UA validator. The release file is an archive with a Java runtime (Eclipse Temurin, cut with jlink): no Java needs to be installed, but the Linux runtimes need glibc. It exits with 1 when a file is not compliant, and writes its configuration to a <c>config</c> folder next to the executable the first time it runs.</summary>
    public static PrebuiltTool VeraPdf { get; } = new("verapdf");

    /// <summary>Gets all the tools.</summary>
    public static IReadOnlyList<PrebuiltTool> All { get; } =
    [
        Zopfli,
        Oxipng,
        Pngout,
        Ffmpeg,
        Ffprobe,
        X265,
        Kvazaar,
        Cwebp,
        Dwebp,
        Webpmux,
        WebpAnimDump,
        Avifenc,
        Avifdec,
        Cjxl,
        Djxl,
        Jxlinfo,
        JxlFromTree,
        JxlOxide,
        HbShape,
        HbInfo,
        HbSubset,
        HbVector,
        HbRaster,
        Woff2Compress,
        Woff2Decompress,
        Woff2Info,
        OpjCompress,
        OpjDecompress,
        OpjDump,
        OjphCompress,
        OjphExpand,
        IsoJpeg,
        Dec265,
        HeifEnc,
        HeifDec,
        HeifInfo,
        HmEncoder,
        HmDecoder,
        Qpdf,
        Mutool,
        Pdftoppm,
        Pdftotext,
        Pdffonts,
        Pdfinfo,
        Pdfsig,
        ArlingtonTestGrammar,
        VeraPdf,
    ];

    private static string? GetCurrentRuntimeIdentifier()
    {
        string? os = null;
        if (OperatingSystem.IsWindows())
        {
            os = "win";
        }
        else if (OperatingSystem.IsLinux())
        {
            os = "linux";
        }
        else if (OperatingSystem.IsMacOS())
        {
            os = "osx";
        }

        var architecture = RuntimeInformation.OSArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            _ => null,
        };

        return os is null || architecture is null ? null : os + "-" + architecture;
    }
}
