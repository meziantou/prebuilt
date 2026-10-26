// exr-to-raw: dumps the header and the decoded samples of an OpenEXR file.
//
//   exr-to-raw [--header-only] <input.exr> <output-directory>
//   exr-to-raw --version
//
// Built against OpenEXR by scripts/build-openexr.sh; see
// src/Meziantou.Prebuilt/README.md for the formats.
//
// It writes <output-directory>/header.json, the description exr-from-raw reads
// (see the top of exr-from-raw.cpp), plus what exr-from-raw ignores, and, for
// every channel of every part, the decoded samples, in the pixel type of the
// channel in the file (no conversion), little-endian: HALF is 2 bytes (the bits
// of the half), FLOAT 4 bytes (the bits of the float, NaN payloads included),
// UINT 4 bytes. The file of channel C of part P is partP.channelC.raw, C being
// the index of the channel in the "channels" list of the part, which is sorted
// by name as in the file.
//
// - Scan line parts: the samples of the data window, row by row from its top
//   (yMin) to its bottom, whatever the line order. A channel with x and y
//   sampling has the samples of the pixels whose x is a multiple of xSampling
//   and y a multiple of ySampling only.
// - Tiled parts: the samples of each level, one level after the other, each
//   level as a scan line part of the data window of the level; MIPMAP_LEVELS
//   in the order of the levels, RIPMAP_LEVELS level (0, 0), (1, 0) ... (nx-1, 0),
//   (0, 1) ... the "levels" list of the part has their (lx, ly) and data window,
//   in that order.
// - Deep parts: partP.sampleCounts.raw has the number of samples of each pixel,
//   as UINT, in the same order; the file of a channel has the samples of the
//   first pixel, then those of the second pixel...
//
// Every attribute of the header in the file that is not a member of the part
// (see isPartMember of exr-raw-common.h) is in its "attributes" list, in the
// order of the file, with its type, its value when the type is known, and
// "data", the bytes of the value in the file in hexadecimal. The attributes
// are read from the bytes of the file: Imf::Header has a "type" for every
// single-part file, and OpenEXRCore a "version" for every part of a file with
// deep data, that are not in the file. A value is written when OpenEXR reads
// the attribute as a value of its type that has the bytes of the file, so a
// malformed value has "data" only. "name" and "chunkCount" are written when
// the file has them.
//
// A part also has "chunkTableOffset", the file offset of its offset table, and
// "chunkTable", the entries of the table as they are in the file: the file
// offset of each chunk, in the order of the table (scan line blocks from the
// top, or tiles level by level and row by row), not in the order of the chunks
// in the file.
//
// Exit codes: 0 when the file was dumped; 1 when OpenEXR cannot read it; 2 for
// a usage error.

#include "exr-raw-common.h"

#include <ImfDeepFrameBuffer.h>
#include <ImfDeepScanLineInputPart.h>
#include <ImfDeepTiledInputPart.h>
#include <ImfFrameBuffer.h>
#include <ImfInputPart.h>
#include <ImfMultiPartInputFile.h>
#include <ImfThreading.h>
#include <ImfTiledInputPart.h>
#include <ImfVersion.h>

#include <Iex.h>
#include <openexr.h>

#include <filesystem>
#include <functional>
#include <fstream>
#include <iostream>

using namespace exrraw;
using IMATH_NAMESPACE::Box2i;

namespace
{

int64_t
floorDiv (int64_t a, int64_t b)
{
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

// The positions in [min, max] that are a multiple of sampling.
struct SampledRange
{
    int64_t first; // index of the first sample: min / sampling, rounded up
    int64_t count;
};

SampledRange
sampledRange (int min, int max, int sampling)
{
    int64_t first = -floorDiv (-int64_t (min), sampling);
    int64_t last  = floorDiv (max, sampling);
    return {first, last >= first ? last - first + 1 : 0};
}

struct Level
{
    int   lx = 0;
    int   ly = 0;
    Box2i dataWindow;
};

struct ChannelOutput
{
    std::string    name;
    Imf::Channel   channel;
    std::string    fileName;
    std::ofstream* stream = nullptr;
};

class Dumper
{
public:
    explicit Dumper (const std::filesystem::path& directory) : _directory (directory) {}

    void write (const std::string& fileName, const void* data, size_t size)
    {
        std::ofstream& stream = open (fileName);
        stream.write (static_cast<const char*> (data), std::streamsize (size));
        if (!stream) throw std::runtime_error ("cannot write " + (_directory / fileName).string ());
    }

    void closeAll ()
    {
        for (auto& entry: _streams)
        {
            entry.second->close ();
            if (!*entry.second) throw std::runtime_error ("cannot write " + (_directory / entry.first).string ());
        }
        _streams.clear ();
    }

private:
    std::filesystem::path _directory;
    std::vector<std::pair<std::string, std::unique_ptr<std::ofstream>>> _streams;

    std::ofstream& open (const std::string& fileName)
    {
        for (auto& entry: _streams)
            if (entry.first == fileName) return *entry.second;
        auto stream = std::make_unique<std::ofstream> (
            _directory / fileName, std::ios::binary | std::ios::trunc);
        if (!*stream) throw std::runtime_error ("cannot create " + (_directory / fileName).string ());
        _streams.emplace_back (fileName, std::move (stream));
        return *_streams.back ().second;
    }
};

std::vector<Level>
levelsOf (const Imf::Header& header, const Box2i& dataWindow,
          int numXLevels, int numYLevels,
          const std::function<Box2i (int, int)>& dataWindowForLevel)
{
    std::vector<Level> levels;
    if (!header.hasTileDescription ())
    {
        levels.push_back ({0, 0, dataWindow});
        return levels;
    }
    switch (header.tileDescription ().mode)
    {
        case Imf::ONE_LEVEL: levels.push_back ({0, 0, dataWindowForLevel (0, 0)}); break;
        case Imf::MIPMAP_LEVELS:
            for (int l = 0; l < numXLevels; l++)
                levels.push_back ({l, l, dataWindowForLevel (l, l)});
            break;
        default:
            for (int ly = 0; ly < numYLevels; ly++)
                for (int lx = 0; lx < numXLevels; lx++)
                    levels.push_back ({lx, ly, dataWindowForLevel (lx, ly)});
            break;
    }
    return levels;
}

// --- Flat (not deep) parts

struct FlatBuffer
{
    std::vector<char> data;
};

// Reads one level into one buffer per channel and appends them to the files.
template <typename ReadLevel>
void
dumpFlatLevel (const std::vector<ChannelOutput>& channels, const Level& level,
               Dumper& dumper, ReadLevel readLevel)
{
    Imf::FrameBuffer        frameBuffer;
    std::vector<FlatBuffer> buffers (channels.size ());
    for (size_t c = 0; c < channels.size (); c++)
    {
        const Imf::Channel& channel = channels[c].channel;
        SampledRange xs = sampledRange (level.dataWindow.min.x, level.dataWindow.max.x, channel.xSampling);
        SampledRange ys = sampledRange (level.dataWindow.min.y, level.dataWindow.max.y, channel.ySampling);
        size_t       sampleSize = size_t (pixelTypeSize (channel.type));
        size_t       xStride    = sampleSize;
        size_t       yStride    = sampleSize * size_t (xs.count);
        buffers[c].data.assign (yStride * size_t (ys.count), 0);
        // The sample of pixel (x, y) is at base + x / xSampling * xStride + y / ySampling * yStride.
        char* base = buffers[c].data.data () - xs.first * int64_t (xStride) - ys.first * int64_t (yStride);
        frameBuffer.insert (
            channels[c].name,
            Imf::Slice (channel.type, base, xStride, yStride, channel.xSampling, channel.ySampling));
    }
    readLevel (frameBuffer);
    for (size_t c = 0; c < channels.size (); c++)
        dumper.write (channels[c].fileName, buffers[c].data.data (), buffers[c].data.size ());
}

// --- Deep parts

template <typename ReadCounts, typename ReadSamples>
void
dumpDeepLevel (const std::vector<ChannelOutput>& channels, const Level& level,
               const std::string& countsFileName, Dumper& dumper,
               ReadCounts readCounts, ReadSamples readSamples)
{
    const Box2i& window = level.dataWindow;
    int64_t      width  = int64_t (window.max.x) - window.min.x + 1;
    int64_t      height = int64_t (window.max.y) - window.min.y + 1;
    if (width <= 0 || height <= 0) return;
    size_t pixels = size_t (width * height);

    std::vector<uint32_t> counts (pixels, 0);
    Imf::DeepFrameBuffer  frameBuffer;
    char* countsBase = reinterpret_cast<char*> (counts.data ()) -
                       (int64_t (window.min.x) + int64_t (window.min.y) * width) * int64_t (sizeof (uint32_t));
    frameBuffer.insertSampleCountSlice (
        Imf::Slice (Imf::UINT, countsBase, sizeof (uint32_t), sizeof (uint32_t) * size_t (width)));

    std::vector<std::vector<char*>> pointers (channels.size (), std::vector<char*> (pixels, nullptr));
    for (size_t c = 0; c < channels.size (); c++)
    {
        char* base = reinterpret_cast<char*> (pointers[c].data ()) -
                     (int64_t (window.min.x) + int64_t (window.min.y) * width) * int64_t (sizeof (char*));
        frameBuffer.insert (
            channels[c].name,
            Imf::DeepSlice (channels[c].channel.type, base, sizeof (char*), sizeof (char*) * size_t (width),
                            size_t (pixelTypeSize (channels[c].channel.type))));
    }
    readCounts (frameBuffer);

    size_t total = 0;
    for (uint32_t count: counts)
        total += count;
    std::vector<std::vector<char>> samples (channels.size ());
    for (size_t c = 0; c < channels.size (); c++)
    {
        size_t sampleSize = size_t (pixelTypeSize (channels[c].channel.type));
        samples[c].assign (total * sampleSize + 1, 0);
        size_t offset = 0;
        for (size_t p = 0; p < pixels; p++)
        {
            pointers[c][p] = samples[c].data () + offset * sampleSize;
            offset += counts[p];
        }
    }
    readSamples (frameBuffer);

    dumper.write (countsFileName, counts.data (), counts.size () * sizeof (uint32_t));
    for (size_t c = 0; c < channels.size (); c++)
        dumper.write (channels[c].fileName, samples[c].data (), samples[c].size () - 1);
}

// The offset table of every part, as it is in the file: the file offset of
// each chunk, in the order of the table (not the order of the chunks in the
// file).
struct ChunkTable
{
    uint64_t              offset = 0; // of the table itself
    std::vector<uint64_t> entries;
};

struct FileAttribute
{
    std::string       name;
    std::string       type;
    std::vector<char> data;
};

// The attributes of a header as they are in the file, and the offset table.
// Both OpenEXR APIs report attributes that are not in the file: Imf::Header
// a "type" for every single-part file, OpenEXRCore a "version" for every part
// of a file with deep data. So the headers are read here, from the bytes.
struct FilePart
{
    ChunkTable                 chunkTable;
    std::vector<FileAttribute> attributes; // in file order

    bool has (const std::string& name) const
    {
        for (const auto& attribute: attributes)
            if (attribute.name == name) return true;
        return false;
    }
};

// The headers of the file: magic number, version field, then the attributes
// of each header (name, type, size, value) up to an empty name; a multi-part
// file has one header per part and an empty one after the last.
std::vector<std::vector<FileAttribute>>
readHeaders (std::ifstream& stream, int parts)
{
    auto readString = [&] (std::string& out) {
        out.clear ();
        for (;;)
        {
            char c = 0;
            if (!stream.get (c)) throw std::runtime_error ("truncated header");
            if (c == '\0') return;
            if (out.size () == 255) throw std::runtime_error ("attribute name or type longer than 255 bytes");
            out += c;
        }
    };
    stream.seekg (8);
    std::vector<std::vector<FileAttribute>> headers (static_cast<size_t> (parts));
    for (auto& header: headers)
    {
        for (;;)
        {
            FileAttribute attribute;
            readString (attribute.name);
            if (attribute.name.empty ()) break;
            readString (attribute.type);
            unsigned char size[4];
            if (!stream.read (reinterpret_cast<char*> (size), 4)) throw std::runtime_error ("truncated header");
            uint32_t length = uint32_t (size[0]) | (uint32_t (size[1]) << 8) | (uint32_t (size[2]) << 16) |
                              (uint32_t (size[3]) << 24);
            if (length > 0x7FFFFFFF) throw std::runtime_error ("negative attribute size");
            attribute.data.resize (length);
            if (length && !stream.read (attribute.data.data (), std::streamsize (length)))
                throw std::runtime_error ("truncated header");
            header.push_back (std::move (attribute));
        }
    }
    return headers;
}

std::vector<FilePart>
readFileParts (const std::string& path, int parts)
{
    exr_context_t             context     = nullptr;
    exr_context_initializer_t initializer = EXR_DEFAULT_CONTEXT_INITIALIZER;
    if (exr_start_read (&context, path.c_str (), &initializer) != EXR_ERR_SUCCESS)
        throw std::runtime_error ("OpenEXRCore cannot read " + path);
    std::vector<FilePart> tables (static_cast<size_t> (parts));
    std::ifstream         stream (std::filesystem::u8path (path), std::ios::binary);
    std::vector<std::vector<FileAttribute>> headers;
    try
    {
        headers = readHeaders (stream, parts);
    }
    catch (...)
    {
        exr_finish (&context);
        throw;
    }
    for (int p = 0; p < parts; p++)
    {
        tables[size_t (p)].attributes = std::move (headers[size_t (p)]);

        ChunkTable& table = tables[size_t (p)].chunkTable;
        int32_t     count = 0;
        if (exr_get_chunk_count (context, p, &count) != EXR_ERR_SUCCESS ||
            exr_get_chunk_table_offset (context, p, &table.offset) != EXR_ERR_SUCCESS)
        {
            exr_finish (&context);
            throw std::runtime_error ("OpenEXRCore cannot read the offset table of part " + std::to_string (p));
        }
        std::vector<unsigned char> bytes (size_t (count) * 8);
        stream.seekg (std::streamoff (table.offset));
        stream.read (reinterpret_cast<char*> (bytes.data ()), std::streamsize (bytes.size ()));
        if (!stream)
        {
            exr_finish (&context);
            throw std::runtime_error ("cannot read the offset table of part " + std::to_string (p));
        }
        for (int32_t i = 0; i < count; i++)
        {
            uint64_t value = 0;
            for (int b = 7; b >= 0; b--)
                value = (value << 8) | bytes[size_t (i) * 8 + size_t (b)];
            table.entries.push_back (value);
        }
    }
    exr_finish (&context);
    return tables;
}

std::string
indent (int level)
{
    return std::string (size_t (level) * 2, ' ');
}

std::string
partJson (const Imf::Header& header, const std::string& type, const std::vector<ChannelOutput>& channels,
          const std::vector<Level>& levels, const FilePart& filePart, int partNumber, bool headerOnly)
{
    const std::string i2 = indent (2), i3 = indent (3);
    std::string       json = indent (1) + "{\n";
    if (filePart.has ("name") && header.hasName ()) json += i2 + "\"name\": " + jsonString (header.name ()) + ",\n";
    json += i2 + "\"type\": " + jsonString (type) + ",\n";
    json += i2 + "\"dataWindow\": " + jsonBox (header.dataWindow ()) + ",\n";
    json += i2 + "\"displayWindow\": " + jsonBox (header.displayWindow ()) + ",\n";
    json += i2 + "\"compression\": " + jsonString (nameOf (compressionNames, header.compression ())) + ",\n";
    json += i2 + "\"lineOrder\": " + jsonString (nameOf (lineOrderNames, header.lineOrder ())) + ",\n";
    json += i2 + "\"pixelAspectRatio\": " + jsonFloat (header.pixelAspectRatio ()) + ",\n";
    json += i2 + "\"screenWindowCenter\": " +
            jsonList ({jsonFloat (header.screenWindowCenter ().x), jsonFloat (header.screenWindowCenter ().y)}) + ",\n";
    json += i2 + "\"screenWindowWidth\": " + jsonFloat (header.screenWindowWidth ()) + ",\n";
    if (header.hasTileDescription ())
        json += i2 + "\"tiles\": " + attributeValueJson (header.typedAttribute<Imf::TileDescriptionAttribute> ("tiles")) + ",\n";
    if (filePart.has ("chunkCount") && header.hasChunkCount ())
        json += i2 + "\"chunkCount\": " + std::to_string (header.chunkCount ()) + ",\n";

    json += i2 + "\"channels\": [";
    for (size_t c = 0; c < channels.size (); c++)
    {
        const Imf::Channel& channel = channels[c].channel;
        json += c ? ",\n" : "\n";
        json += i3 + "{\"name\": " + jsonString (channels[c].name) +
                ", \"pixelType\": " + jsonString (nameOf (pixelTypeNames, channel.type)) +
                ", \"xSampling\": " + std::to_string (channel.xSampling) +
                ", \"ySampling\": " + std::to_string (channel.ySampling) +
                ", \"pLinear\": " + (channel.pLinear ? "true" : "false");
        if (!headerOnly) json += ", \"file\": " + jsonString (channels[c].fileName);
        json += "}";
    }
    json += channels.empty () ? "],\n" : "\n" + i2 + "],\n";

    if (Imf::isDeepData (type) && !headerOnly)
        json += i2 + "\"sampleCounts\": " + jsonString ("part" + std::to_string (partNumber) + ".sampleCounts.raw") + ",\n";

    if (header.hasTileDescription ())
    {
        json += i2 + "\"levels\": [";
        for (size_t l = 0; l < levels.size (); l++)
        {
            json += l ? ",\n" : "\n";
            json += i3 + "{\"level\": [" + std::to_string (levels[l].lx) + ", " + std::to_string (levels[l].ly) +
                    "], \"dataWindow\": " + jsonBox (levels[l].dataWindow) + "}";
        }
        json += "\n" + i2 + "],\n";
    }

    const ChunkTable& chunkTable = filePart.chunkTable;
    json += i2 + "\"chunkTableOffset\": " + std::to_string (chunkTable.offset) + ",\n";
    json += i2 + "\"chunkTable\": [";
    for (size_t c = 0; c < chunkTable.entries.size (); c++)
        json += (c ? ", " : "") + std::to_string (chunkTable.entries[c]);
    json += "],\n";

    json += i2 + "\"attributes\": [";
    bool first = true;
    for (const FileAttribute& fileAttribute: filePart.attributes)
    {
        if (isPartMember (fileAttribute.name)) continue;
        json += first ? "\n" : ",\n";
        first = false;
        json += i3 + "{\"name\": " + jsonString (fileAttribute.name) + ", \"type\": " + jsonString (fileAttribute.type);
        // The value as OpenEXR reads it, when it is of a known type and its
        // bytes are those of the file: OpenEXR reads some malformed values
        // as something else, or as nothing.
        auto it = header.find (fileAttribute.name);
        if (it != header.end () && fileAttribute.type == it.attribute ().typeName () &&
            attributeBytes (it.attribute ()) == fileAttribute.data)
        {
            std::string value = attributeValueJson (it.attribute ());
            if (!value.empty ()) json += ", \"value\": " + value;
        }
        json += ", \"data\": \"" + hex (fileAttribute.data.data (), fileAttribute.data.size ()) + "\"}";
    }
    json += first ? "]\n" : "\n" + i2 + "]\n";
    json += indent (1) + "}";
    return json;
}

int
run (int argc, char* argv[])
{
    bool        headerOnly = false;
    std::string input, output;
    for (int i = 1; i < argc; i++)
    {
        std::string arg = argv[i];
        if (arg == "--version")
        {
            std::cout << "exr-to-raw (OpenEXR " << EXR_RAW_TOOLS_OPENEXR_VERSION << ")\n";
            return 0;
        }
        if (arg == "-h" || arg == "--help")
        {
            std::cout << "usage: exr-to-raw [--header-only] <input.exr> <output-directory>\n";
            return 0;
        }
        if (arg == "--header-only")
            headerOnly = true;
        else if (!arg.empty () && arg[0] == '-' && arg != "-")
            fail ("unknown option " + arg);
        else if (input.empty ())
            input = arg;
        else if (output.empty ())
            output = arg;
        else
            fail ("too many arguments");
    }
    if (input.empty () || output.empty ()) fail ("usage: exr-to-raw [--header-only] <input.exr> <output-directory>");

    Imf::setGlobalThreadCount (0);
    // Without the reconstruction of a damaged offset table: a file OpenEXR
    // would have to repair is reported as an error.
    Imf::MultiPartInputFile file (input.c_str (), 0, false);

    std::filesystem::path directory (output);
    std::filesystem::create_directories (directory);
    Dumper dumper (directory);

    std::vector<FilePart> fileParts = readFileParts (input, file.parts ());
    int                     version     = file.version ();
    std::string json    = "{\n";
    json += indent (1) + "\"openexr\": " + jsonString (EXR_RAW_TOOLS_OPENEXR_VERSION) + ",\n";
    json += indent (1) + "\"versionField\": " + std::to_string (version) + ",\n";
    json += indent (1) + "\"flags\": {\"tiled\": " + (Imf::isTiled (version) ? "true" : "false") +
            ", \"longNames\": " + ((version & Imf::LONG_NAMES_FLAG) ? "true" : "false") +
            ", \"nonImage\": " + ((version & Imf::NON_IMAGE_FLAG) ? "true" : "false") +
            ", \"multiPart\": " + ((version & Imf::MULTI_PART_FILE_FLAG) ? "true" : "false") + "},\n";
    json += indent (1) + "\"parts\": [\n";

    for (int p = 0; p < file.parts (); p++)
    {
        const Imf::Header& header = file.header (p);
        std::string        type   = header.hasType ()     ? header.type ()
                                    : header.hasTileDescription () ? Imf::TILEDIMAGE
                                                                   : Imf::SCANLINEIMAGE;
        std::vector<ChannelOutput> channels;
        for (auto it = header.channels ().begin (); it != header.channels ().end (); ++it)
            channels.push_back ({it.name (), it.channel (),
                                 "part" + std::to_string (p) + ".channel" + std::to_string (channels.size ()) + ".raw"});
        std::string countsFileName = "part" + std::to_string (p) + ".sampleCounts.raw";

        std::vector<Level> levels;
        if (type == Imf::SCANLINEIMAGE)
        {
            levels = levelsOf (header, header.dataWindow (), 1, 1, nullptr);
            if (!headerOnly)
            {
                Imf::InputPart part (file, p);
                dumpFlatLevel (channels, levels[0], dumper, [&] (Imf::FrameBuffer& frameBuffer) {
                    part.setFrameBuffer (frameBuffer);
                    part.readPixels (header.dataWindow ().min.y, header.dataWindow ().max.y);
                });
            }
        }
        else if (type == Imf::TILEDIMAGE)
        {
            Imf::TiledInputPart part (file, p);
            levels = levelsOf (header, header.dataWindow (), part.numXLevels (), part.numYLevels (),
                               [&] (int lx, int ly) { return part.dataWindowForLevel (lx, ly); });
            if (!headerOnly)
                for (const Level& level: levels)
                    dumpFlatLevel (channels, level, dumper, [&] (Imf::FrameBuffer& frameBuffer) {
                        part.setFrameBuffer (frameBuffer);
                        part.readTiles (0, part.numXTiles (level.lx) - 1, 0, part.numYTiles (level.ly) - 1,
                                        level.lx, level.ly);
                    });
        }
        else if (type == Imf::DEEPSCANLINE)
        {
            levels = levelsOf (header, header.dataWindow (), 1, 1, nullptr);
            if (!headerOnly)
            {
                Imf::DeepScanLineInputPart part (file, p);
                const Box2i&               window = header.dataWindow ();
                dumpDeepLevel (
                    channels, levels[0], countsFileName, dumper,
                    [&] (Imf::DeepFrameBuffer& frameBuffer) {
                        part.setFrameBuffer (frameBuffer);
                        part.readPixelSampleCounts (window.min.y, window.max.y);
                    },
                    [&] (Imf::DeepFrameBuffer&) { part.readPixels (window.min.y, window.max.y); });
            }
        }
        else if (type == Imf::DEEPTILE)
        {
            Imf::DeepTiledInputPart part (file, p);
            levels = levelsOf (header, header.dataWindow (), part.numXLevels (), part.numYLevels (),
                               [&] (int lx, int ly) { return part.dataWindowForLevel (lx, ly); });
            if (!headerOnly)
                for (const Level& level: levels)
                {
                    int nx = part.numXTiles (level.lx), ny = part.numYTiles (level.ly);
                    dumpDeepLevel (
                        channels, level, countsFileName, dumper,
                        [&] (Imf::DeepFrameBuffer& frameBuffer) {
                            part.setFrameBuffer (frameBuffer);
                            part.readPixelSampleCounts (0, nx - 1, 0, ny - 1, level.lx, level.ly);
                        },
                        [&] (Imf::DeepFrameBuffer&) { part.readTiles (0, nx - 1, 0, ny - 1, level.lx, level.ly); });
                }
        }
        else
            fail ("part " + std::to_string (p) + " has the unknown type \"" + type + "\"");

        json += partJson (header, type, channels, levels, fileParts[size_t (p)], p, headerOnly);
        json += p + 1 < file.parts () ? ",\n" : "\n";
    }
    json += indent (1) + "]\n}\n";

    dumper.closeAll ();
    std::ofstream stream (directory / "header.json", std::ios::binary | std::ios::trunc);
    stream << json;
    stream.close ();
    if (!stream) throw std::runtime_error ("cannot write " + (directory / "header.json").string ());
    return 0;
}

} // namespace

int
main (int argc, char* argv[])
{
    try
    {
        return run (argc, argv);
    }
    catch (const UsageError& e)
    {
        std::cerr << "exr-to-raw: " << e.what () << "\n";
        return 2;
    }
    catch (const std::exception& e)
    {
        std::cerr << "exr-to-raw: " << e.what () << "\n";
        return 1;
    }
}
