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

    /// <summary>ssimulacra2, the libjxl developer tool that prints the SSIMULACRA 2 score of a distorted image against an original (100: the same image; PNG, PPM, PFM, JPEG XL, ... files).</summary>
    public static PrebuiltTool Ssimulacra2 { get; } = new("ssimulacra2");

    /// <summary>butteraugli_main, the libjxl developer tool that prints the Butteraugli distance of a distorted image against a reference (the maximum, then the p-norm with <c>--pnorm</c>; 0: the same image), and writes a distance map with <c>--distmap</c>.</summary>
    public static PrebuiltTool Butteraugli { get; } = new("butteraugli_main");

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

    /// <summary>exrheader, the OpenEXR tool that prints the header of every part of an EXR file.</summary>
    public static PrebuiltTool ExrHeader { get; } = new("exrheader");

    /// <summary>exrinfo, the OpenEXR tool that prints the header attributes of an EXR file, read with OpenEXRCore.</summary>
    public static PrebuiltTool ExrInfo { get; } = new("exrinfo");

    /// <summary>exrmaketiled, the OpenEXR tool that writes a tiled version of an EXR file, with one level, mipmaps or ripmaps.</summary>
    public static PrebuiltTool ExrMakeTiled { get; } = new("exrmaketiled");

    /// <summary>exrmetrics, the OpenEXR tool that measures how fast and how small each compression writes a file, and, with <c>--convert</c>, writes the file again with another compression (<c>-z</c>) or pixel type (<c>--pixelmode</c>).</summary>
    public static PrebuiltTool ExrMetrics { get; } = new("exrmetrics");

    /// <summary>exrstdattr, the OpenEXR tool that sets standard attributes (chromaticities, owner, ...) in the headers of an EXR file.</summary>
    public static PrebuiltTool ExrStdAttr { get; } = new("exrstdattr");

    /// <summary>exrcheck, the OpenEXR tool that reads an EXR file with every API of the library to validate it. It also reports some valid files as bad: see the README.</summary>
    public static PrebuiltTool ExrCheck { get; } = new("exrcheck");

    /// <summary>exrmultipart, the OpenEXR tool that combines EXR files into a multi-part file, or separates one. <c>-combine</c> leaves offset tables filled with zeros: see the README.</summary>
    public static PrebuiltTool ExrMultiPart { get; } = new("exrmultipart");

    /// <summary>exrmultiview, the OpenEXR tool that combines single-view EXR files into a multi-view file.</summary>
    public static PrebuiltTool ExrMultiView { get; } = new("exrmultiview");

    /// <summary>exrenvmap, the OpenEXR tool that converts a latitude-longitude environment map into a cube-face one, or the other way around.</summary>
    public static PrebuiltTool ExrEnvMap { get; } = new("exrenvmap");

    /// <summary>exrmakepreview, the OpenEXR tool that adds a preview image to the header of an EXR file.</summary>
    public static PrebuiltTool ExrMakePreview { get; } = new("exrmakepreview");

    /// <summary>exrmanifest, the OpenEXR tool that prints the ID manifest embedded in an EXR file.</summary>
    public static PrebuiltTool ExrManifest { get; } = new("exrmanifest");

    /// <summary>exr2aces, the deprecated OpenEXR tool that writes an EXR file as an ACES image container file.</summary>
    public static PrebuiltTool Exr2Aces { get; } = new("exr2aces");

    /// <summary>exr-from-raw, a program of meziantou/prebuilt built with OpenEXR that writes an EXR file from a JSON description of its header and files of raw samples: every compression, pixel type, sampling, line order, tiles, levels, deep data, multi-part files, and any attribute. See the README for the format.</summary>
    public static PrebuiltTool ExrFromRaw { get; } = new("exr-from-raw");

    /// <summary>exr-to-raw, a program of meziantou/prebuilt built with OpenEXR that dumps the header of an EXR file as JSON and its decoded samples as raw little-endian files, bit for bit. See the README for the format.</summary>
    public static PrebuiltTool ExrToRaw { get; } = new("exr-to-raw");

    /// <summary>iso-jpeg, the <c>jpeg</c> tool of the ISO JPEG reference codec (thorfdbg/libjpeg): a JPEG encoder and decoder that shares no code with libjpeg-turbo, with arithmetic coding, 12-bit samples, and the progressive and hierarchical processes. It exits with 0 when a conversion fails: delete the output file first, and check afterwards that it exists and is not empty.</summary>
    public static PrebuiltTool IsoJpeg { get; } = new("iso-jpeg");

    /// <summary>pvalue, the Radiance tool that dumps the pixels of a Radiance picture (.hdr, RGBE or XYZE) as text or binary values (<c>-df</c>: little-endian floats), or writes a picture from them with <c>-r</c> (run-length encoded, or flat with <c>-u</c>; <c>-pXYZ</c> for XYZE), in any of the 8 scan line orders.</summary>
    public static PrebuiltTool Pvalue { get; } = new("pvalue");

    /// <summary>getinfo, the Radiance tool that prints the header of a Radiance picture, or its resolution string with <c>-d</c>, and adds header lines with <c>-a</c>.</summary>
    public static PrebuiltTool RadianceGetInfo { get; } = new("getinfo");

    /// <summary>pflip, the Radiance tool that flips a Radiance picture horizontally (<c>-h</c>) or vertically (<c>-v</c>). Without <c>-c</c>, it changes the scan line order and the resolution string, and the image stays the same.</summary>
    public static PrebuiltTool Pflip { get; } = new("pflip");

    /// <summary>protate, the Radiance tool that rotates a Radiance picture by 90 degrees. Without <c>-c</c>, it changes the scan line order and the resolution string (<c>+X</c>/<c>-X</c> first), and the image stays the same.</summary>
    public static PrebuiltTool Protate { get; } = new("protate");

    /// <summary>ra_xyze, the Radiance tool that converts a Radiance picture from RGBE to XYZE (flat, or run-length encoded with <c>-c</c>), or back to RGBE with <c>-r</c>.</summary>
    public static PrebuiltTool RaXyze { get; } = new("ra_xyze");

    /// <summary>ra_rgbe, the Radiance tool that writes a Radiance picture with flat scan lines, or run-length encoded ones with <c>-r</c>.</summary>
    public static PrebuiltTool RaRgbe { get; } = new("ra_rgbe");

    /// <summary>ra_ppm, the Radiance tool that converts a Radiance picture to a PPM file (8 or 16 bits), or a PPM file to a Radiance picture with <c>-r</c>.</summary>
    public static PrebuiltTool RaPpm { get; } = new("ra_ppm");

    /// <summary>ra_bmp, the Radiance tool that converts a Radiance picture to a BMP file, or a BMP file to a Radiance picture with <c>-r</c>.</summary>
    public static PrebuiltTool RaBmp { get; } = new("ra_bmp");

    /// <summary>magick, the command-line tool of ImageMagick 7 (Q16, HDRI), built with zlib, LittleCMS 2, libpng and libtiff only: the writer of PSD and PSB files (RGB, CMYK, grayscale, indexed and bitmap, 8 or 16 bits, raw or RLE, with layers, alpha and an ICC profile) and a reader of them (also 32 bits), and of PNG, TIFF, PNM, BMP and raw samples. Write PSD files with <c>-endian MSB</c> after the input images, and read them with <c>-define psd:alpha-unblend=off</c> to get the colors of a composite with alpha as stored.</summary>
    public static PrebuiltTool Magick { get; } = new("magick");

    /// <summary>psd-tools, the command-line tool of meziantou/prebuilt for the psd-tools Python library, which shares no code with ImageMagick: <c>dump</c> writes the description of a PSD or PSB file as JSON and the samples of its composite and layers as raw files, as stored; <c>write</c> writes a file from them (every color mode, 1, 8, 16 and 32 bits, raw, RLE, ZIP and ZIP with prediction, layers in the layer info or in Lr16/Lr32 blocks, masks, ICC profile, no real composite). The release file is an archive with a Python runtime: no Python needs to be installed, but the Linux runtimes need glibc 2.28. See the README for the format.</summary>
    public static PrebuiltTool PsdTools { get; } = new("psd-tools");

    /// <summary>astcenc, the ASTC encoder and decoder of Arm, LDR and HDR (<c>-cl</c>, <c>-cs</c>, <c>-ch</c>, <c>-cH</c> to compress; <c>-dl</c>, <c>-ds</c>, <c>-dh</c>, <c>-dH</c> to decompress; <c>-tl</c>... to compress and decompress), every 2D and 3D block size, reading and writing PNG, TGA, BMP, HDR, EXR, KTX and DDS files. It is built for no SIMD instruction set: it writes the same bytes on every runtime identifier.</summary>
    public static PrebuiltTool Astcenc { get; } = new("astcenc");

    /// <summary>basisu, the Basis Universal encoder, transcoder and validator: it writes .basis and KTX2 files (ETC1S with BasisLZ, UASTC LDR 4x4 and the HDR formats with Zstandard supercompression; mipmaps, cube maps, arrays), shows them (<c>-info</c>), checks them (<c>-validate</c>) and transcodes them to BC1 to BC7, ETC1, ETC2, EAC, ASTC, PVRTC1 and PNG files (<c>-unpack</c>). It is built without SSE: it writes the same bytes on every runtime identifier.</summary>
    public static PrebuiltTool Basisu { get; } = new("basisu");

    /// <summary>ktx, the command-line tool of KTX-Software: <c>create</c> (from raw samples with <c>--raw</c>, or PNG, EXR, ...; mip levels, cube maps, arrays, 3D; <c>--encode basis-lz</c> or <c>uastc</c>, <c>--zstd</c>), <c>extract</c>, <c>info</c> (JSON with <c>-f json</c>), <c>validate</c>, <c>transcode</c>, <c>encode</c>, <c>deflate</c>, <c>compare</c>. <c>--testrun</c> writes no version into the files.</summary>
    public static PrebuiltTool Ktx { get; } = new("ktx");

    /// <summary>toktx, the legacy KTX-Software tool that writes KTX and KTX2 (<c>--t2</c>) files from PNG and Netpbm files, with generated mipmaps (<c>--genmipmap</c>), Basis Universal (<c>--encode etc1s</c> or <c>uastc</c>) and Zstandard (<c>--zcmp</c>).</summary>
    public static PrebuiltTool Toktx { get; } = new("toktx");

    /// <summary>ktx2check, the legacy KTX-Software validator of KTX2 files: it exits with 0 for a valid file.</summary>
    public static PrebuiltTool Ktx2Check { get; } = new("ktx2check");

    /// <summary>dcraw_emu, the LibRaw sample that renders camera raw and DNG files as dcraw does: PPM or TIFF (<c>-T</c>) files, 8 or linear 16 bits (<c>-4</c>), any output color space (<c>-o</c>), white balance (<c>-w</c>, <c>-r</c>), half size (<c>-h</c>), demosaicing quality (<c>-q</c>). Built with zlib (deflate DNG), libjpeg-turbo (lossy DNG) and LittleCMS 2.</summary>
    public static PrebuiltTool DcrawEmu { get; } = new("dcraw_emu");

    /// <summary>raw-identify, the LibRaw sample that names the camera of a raw or DNG file, and prints its sizes, filter pattern, color matrices and metadata with <c>-v</c>.</summary>
    public static PrebuiltTool RawIdentify { get; } = new("raw-identify");

    /// <summary>unprocessed_raw, the LibRaw sample that writes the CFA samples of a raw or DNG file, as stored, to a 16-bit PGM file (<c>-T</c>: TIFF).</summary>
    public static PrebuiltTool UnprocessedRaw { get; } = new("unprocessed_raw");

    /// <summary>TAppEncoderSCM, the encoder of HM-SCM, the HEVC reference software with the screen content coding extensions (profile <c>main-SCC</c>: <c>--PaletteMode</c>, <c>--IntraBlockCopyEnabled</c>, <c>--ColourTransform</c>, <c>--MotionVectorResolutionControlIdc</c>), built with high bit depth support.</summary>
    public static PrebuiltTool HmScmEncoder { get; } = new("TAppEncoderSCM");

    /// <summary>TAppDecoderSCM, the decoder of HM-SCM: HEVC version 1, range and screen content coding extensions.</summary>
    public static PrebuiltTool HmScmDecoder { get; } = new("TAppDecoderSCM");

    /// <summary>texconv, the DirectXTex tool that converts images to DDS files (BC1 to BC7, BC6H, every DXGI format; <c>-m</c> mip levels, <c>-dx10</c> header) and DDS files to images (<c>-ft</c>). Windows only; built with the CPU encoders only: it never uses the GPU, and writes the same bytes on every machine.</summary>
    public static PrebuiltTool Texconv { get; } = new("texconv");

    /// <summary>texdiag, the DirectXTex tool that describes (<c>info</c>), analyzes, compares and dumps DDS files. Windows only.</summary>
    public static PrebuiltTool Texdiag { get; } = new("texdiag");

    /// <summary>texassemble, the DirectXTex tool that assembles cube maps (<c>cube</c>), arrays (<c>array</c>), volume textures and cube arrays from images (<c>-dx10</c>: a DX10 header). Windows only.</summary>
    public static PrebuiltTool Texassemble { get; } = new("texassemble");

    /// <summary>iccFromXml, the iccDEV (DemoIccMAX) tool that writes an ICC profile (version 2 to 5, iccMAX) from its XML description.</summary>
    public static PrebuiltTool IccFromXml { get; } = new("iccFromXml");

    /// <summary>iccToXml, the iccDEV tool that writes the XML description of an ICC profile; iccFromXml writes the same bytes again from it.</summary>
    public static PrebuiltTool IccToXml { get; } = new("iccToXml");

    /// <summary>iccFromJson, the iccDEV tool that writes an ICC profile from its JSON description.</summary>
    public static PrebuiltTool IccFromJson { get; } = new("iccFromJson");

    /// <summary>iccToJson, the iccDEV tool that writes the JSON description of an ICC profile.</summary>
    public static PrebuiltTool IccToJson { get; } = new("iccToJson");

    /// <summary>iccDumpProfile, the iccDEV tool that prints the header and tags of an ICC profile, and validates it with <c>-v</c>.</summary>
    public static PrebuiltTool IccDumpProfile { get; } = new("iccDumpProfile");

    /// <summary>iccRoundTrip, the iccDEV tool that reports the round-trip accuracy of an ICC profile.</summary>
    public static PrebuiltTool IccRoundTrip { get; } = new("iccRoundTrip");

    /// <summary>iccApplyNamedCmm, the iccDEV tool that applies a chain of ICC profiles (D2Bx/B2Dx, A2Bx/B2Ax, matrix/TRC, named colors with tints) to the values of a text file, with any encoding (floats, 8 or 16 bits, ...).</summary>
    public static PrebuiltTool IccApplyNamedCmm { get; } = new("iccApplyNamedCmm");

    /// <summary>iccApplyToLink, the iccDEV tool that writes a device link profile or a 3D LUT (.cube) from a chain of ICC profiles.</summary>
    public static PrebuiltTool IccApplyToLink { get; } = new("iccApplyToLink");

    /// <summary>opencv-oracle, a program of meziantou/prebuilt built with OpenCV that runs one OpenCV function on a PNG file or raw samples and prints its result as JSON: <c>hough-lines</c>, <c>hough-lines-p</c>, <c>harris</c> (and its response as raw floats), <c>good-features</c>, <c>fast</c>, <c>homography</c> (DLT, RANSAC, LMEDS, RHO, with a seed) and <c>inpaint</c> (Telea, Navier-Stokes). See the README for the commands.</summary>
    public static PrebuiltTool OpenCvOracle { get; } = new("opencv-oracle");

    /// <summary>oiiotool, the OpenImageIO tool that reads, converts and processes images: it reads PSD, DPX, Cineon, DDS, HDR, TIFF, PNG, OpenEXR, camera raw and DNG (LibRaw; <c>-iconfig raw:Demosaic none</c> for the CFA samples), BMP, TGA, PNM, ... and writes DPX, HDR, TIFF, PNG, OpenEXR, ...; <c>-v --info --dumpdata</c> prints every pixel. Its PNM writer writes the rows bottom-up.</summary>
    public static PrebuiltTool OiioTool { get; } = new("oiiotool");

    /// <summary>iinfo, the OpenImageIO tool that prints the size, format, channels and metadata of images (<c>-v</c>), their statistics (<c>--stats</c>) and the hash of their pixels (<c>--hash</c>).</summary>
    public static PrebuiltTool Iinfo { get; } = new("iinfo");

    /// <summary>dng_validate, the tool of the Adobe DNG SDK that validates DNG files (<c>-v</c> prints their tags) and writes their stage 1 (the raw samples, as stored), stage 2 (linearized) and stage 3 (demosaiced) images (<c>-1</c>, <c>-2</c>, <c>-3</c>), the rendered image (<c>-tif</c>, <c>-16</c> for 16 bits) and DNG files (<c>-dng</c>; <c>-losslessJXL</c> for DNG 1.7 with JPEG XL).</summary>
    public static PrebuiltTool DngValidate { get; } = new("dng_validate");

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

    /// <summary>pdfium_test, the command-line tool of PDFium, configured as the PDFium pixel tests are run (AGG renderer, no V8 or XFA). The release file is an archive: the folder of the executable also holds <c>test_fonts/</c> and <c>fonts/</c>, the fonts of the pixel tests (<c>--png --md5 --time=1399672130 --font-dir=&lt;folder&gt;/test_fonts --croscore-font-names</c>). Its version is the N of the chromium/N branch it is built from. The Linux builds need glibc and libgcc_s.</summary>
    public static PrebuiltTool PdfiumTest { get; } = new("pdfium_test");

    /// <summary>zint, the barcode encoder of the zint library (QR Code, Micro QR, rMQR, Code 128, Code 39, Code 93, EAN/UPC with their add-ons, Codabar, Interleaved 2 of 5, ...), built with libpng and without the GS1 Syntax Engine. <c>--dump</c> prints the module matrix, one row per line, in hexadecimal: 4 modules per digit, the first one in the high bit, in groups of 2 digits, the last group with the digits the row needs only. <c>-b</c> selects the symbology, and <c>--vers</c>, <c>--mask</c> and <c>--secure</c> pin the version, the mask and the error correction level.</summary>
    public static PrebuiltTool Zint { get; } = new("zint");

    /// <summary>ZXingReader, the barcode reader of the example programs of zxing-cpp, built with every reader. It reads PNG, BMP, GIF, JPEG, PNM and TGA files (stb_image), and prints the text, format, version, error correction level and mask of each barcode (<c>-1</c> for one line per barcode, <c>-json</c>, <c>-symbol</c> for the module matrix). It exits with 0 when it cannot load an image.</summary>
    public static PrebuiltTool ZXingReader { get; } = new("ZXingReader");

    /// <summary>zbarimg, the image scanner of ZBar (EAN/UPC with their add-ons, DataBar, Code 128, Code 93, Code 39, Codabar, Interleaved 2 of 5, QR Code, SQ Code; not Micro QR or rMQR), built with GraphicsMagick for PNG, BMP, GIF, PCX, PNM and TGA files (no JPEG or TIFF). It exits with 4 when it finds no barcode. ZBar is available under the GNU Lesser General Public License, version 2.1 or later.</summary>
    public static PrebuiltTool ZBarImg { get; } = new("zbarimg");

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
        Ssimulacra2,
        Butteraugli,
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
        ExrHeader,
        ExrInfo,
        ExrMakeTiled,
        ExrMetrics,
        ExrStdAttr,
        ExrCheck,
        ExrMultiPart,
        ExrMultiView,
        ExrEnvMap,
        ExrMakePreview,
        ExrManifest,
        Exr2Aces,
        ExrFromRaw,
        ExrToRaw,
        IsoJpeg,
        Pvalue,
        RadianceGetInfo,
        Pflip,
        Protate,
        RaXyze,
        RaRgbe,
        RaPpm,
        RaBmp,
        Magick,
        PsdTools,
        Astcenc,
        Basisu,
        Ktx,
        Toktx,
        Ktx2Check,
        DcrawEmu,
        RawIdentify,
        UnprocessedRaw,
        HmScmEncoder,
        HmScmDecoder,
        Texconv,
        Texdiag,
        Texassemble,
        IccFromXml,
        IccToXml,
        IccFromJson,
        IccToJson,
        IccDumpProfile,
        IccRoundTrip,
        IccApplyNamedCmm,
        IccApplyToLink,
        OpenCvOracle,
        OiioTool,
        Iinfo,
        DngValidate,
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
        PdfiumTest,
        Zint,
        ZXingReader,
        ZBarImg,
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
