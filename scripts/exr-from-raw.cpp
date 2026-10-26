// exr-from-raw: writes an OpenEXR file from raw samples and a JSON description
// of its header.
//
//   exr-from-raw <description.json> <output.exr>
//   exr-from-raw --version
//
// Built against OpenEXR by scripts/build-openexr.sh; see
// src/Meziantou.Prebuilt/README.md for the formats.
//
// The description is the header.json that exr-to-raw writes, so a dump can be
// written back. It is an object with "parts", an array of parts, or a part
// itself, for a single-part file. A file with more than one part is a
// multi-part file. A part is an object with:
//
//   "type"                "scanlineimage" (default), "tiledimage" (default
//                         when "tiles" is given), "deepscanline" or "deeptile"
//   "name"                optional; required for every part of a multi-part file
//   "dataWindow"          [xMin, yMin, xMax, yMax], required
//   "displayWindow"       [xMin, yMin, xMax, yMax], default: the data window
//   "compression"         NONE, RLE, ZIPS, ZIP (default), PIZ, PXR24, B44, B44A,
//                         DWAA, DWAB, HTJ2K256, HTJ2K32, LJ2K or ZSTD
//   "lineOrder"           INCREASING_Y (default), DECREASING_Y or RANDOM_Y
//   "pixelAspectRatio"    default 1
//   "screenWindowCenter"  [x, y], default [0, 0]
//   "screenWindowWidth"   default 1
//   "tiles"               {"xSize", "ySize", "levelMode": ONE_LEVEL (default),
//                         MIPMAP_LEVELS or RIPMAP_LEVELS, "roundingMode":
//                         ROUND_DOWN (default) or ROUND_UP}
//   "zipCompressionLevel", "dwaCompressionLevel", "zstdCompressionLevel"
//                         optional: settings of the encoder, not stored in
//                         the file (OpenEXR defaults: 4, 45 and 5)
//   "channels"            [{"name", "pixelType": HALF (default), FLOAT or
//                         UINT, "xSampling" and "ySampling" (default 1),
//                         "pLinear" (default false), "file"}]
//   "sampleCounts"        deep parts: the file of the sample counts
//   "attributes"          [{"name", "type", "value"} or {"name", "type", "data"}]
//
// "file" and "sampleCounts" are paths relative to the folder of the
// description, of files laid out as exr-to-raw writes them (see the top of
// exr-to-raw.cpp): the samples in the pixel type of the channel,
// little-endian, row by row from the top of the data window, for every level
// of a tiled part, one after the other. Without "file", the samples are zeros;
// without "sampleCounts", every pixel of a deep part has no sample.
//
// An attribute with a "value" is of one of the types attributeFromJson of
// exr-raw-common.h knows. With "data", the bytes of the value in hexadecimal,
// it can be of any type, and is written as it is, even when the bytes are not
// a valid value of a known type. "value" wins when both are given, as in the
// header.json of exr-to-raw. The attributes that are members of the part
// (channels, compression, dataWindow...) cannot be in this list.
//
// The tiles of a part whose line order is RANDOM_Y are written in an order
// shuffled with a fixed seed, the same on every run and every platform; the
// other tiled parts are written in the order of their line order. A
// single-part file is written as OpenEXR's OutputFile, TiledOutputFile,
// DeepScanLineOutputFile and DeepTiledOutputFile write it, and a multi-part
// file as MultiPartOutputFile does: the "type" attribute is written for the
// parts of a multi-part file and for deep parts only.
//
// What exr-to-raw adds to header.json is ignored: "openexr", "versionField"
// and "flags" at the top, "chunkCount", "levels", "chunkTableOffset" and
// "chunkTable" in a part.
//
// Exit codes: 0 when the file was written; 1 when OpenEXR refuses the header
// or the samples (the output file is then deleted); 2 for a usage error or an
// invalid description.

#include "exr-raw-common.h"

#include <ImfDeepFrameBuffer.h>
#include <ImfDeepScanLineOutputFile.h>
#include <ImfDeepScanLineOutputPart.h>
#include <ImfDeepTiledOutputFile.h>
#include <ImfDeepTiledOutputPart.h>
#include <ImfFrameBuffer.h>
#include <ImfMultiPartOutputFile.h>
#include <ImfOutputFile.h>
#include <ImfOutputPart.h>
#include <ImfThreading.h>
#include <ImfTiledOutputFile.h>
#include <ImfTiledOutputPart.h>

#include <filesystem>
#include <functional>
#include <fstream>
#include <iostream>
#include <iterator>
#include <set>
#include <sstream>

using namespace exrraw;
using IMATH_NAMESPACE::Box2i;
using IMATH_NAMESPACE::V2f;

namespace
{

int64_t
floorDiv (int64_t a, int64_t b)
{
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

struct SampledRange
{
    int64_t first;
    int64_t count;
};

SampledRange
sampledRange (int min, int max, int sampling)
{
    int64_t first = -floorDiv (-int64_t (min), sampling);
    int64_t last  = floorDiv (max, sampling);
    return {first, last >= first ? last - first + 1 : 0};
}

std::vector<char>
readFile (const std::filesystem::path& path)
{
    std::ifstream stream (path, std::ios::binary);
    if (!stream) fail ("cannot open " + path.string ());
    return std::vector<char> (std::istreambuf_iterator<char> (stream), std::istreambuf_iterator<char> ());
}

void
checkMembers (const Json& object, const std::string& what, std::initializer_list<const char*> known,
              std::initializer_list<const char*> ignored = {})
{
    for (const auto& member: object.members)
    {
        bool found = false;
        for (const char* name: known)
            found = found || member.first == name;
        for (const char* name: ignored)
            found = found || member.first == name;
        if (!found) fail (what + " has the unknown member \"" + member.first + "\"");
    }
}

struct Level
{
    int   lx = 0;
    int   ly = 0;
    Box2i dataWindow;
};

struct ChannelInput
{
    std::string           name;
    Imf::Channel          channel;
    std::filesystem::path file; // empty: zeros
    std::vector<char>     data; // every level, one after the other
};

struct Part
{
    Imf::Header               header;
    std::string               type;
    std::vector<ChannelInput> channels;
    std::filesystem::path     sampleCountsFile;
    std::vector<uint32_t>     sampleCounts; // deep parts, every level
    std::vector<Level>        levels;
};

// The levels of a part, in the order of the files (see the top of
// exr-to-raw.cpp), from what OpenEXR computes for the part.
std::vector<Level>
levelsOf (const Imf::Header& header, int numXLevels, int numYLevels,
          const std::function<Box2i (int, int)>& dataWindowForLevel)
{
    std::vector<Level> levels;
    if (!header.hasTileDescription ())
    {
        levels.push_back ({0, 0, header.dataWindow ()});
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

size_t
samplesInLevel (const Imf::Channel& channel, const Level& level)
{
    SampledRange xs = sampledRange (level.dataWindow.min.x, level.dataWindow.max.x, channel.xSampling);
    SampledRange ys = sampledRange (level.dataWindow.min.y, level.dataWindow.max.y, channel.ySampling);
    return size_t (xs.count) * size_t (ys.count);
}

size_t
pixelsInLevel (const Level& level)
{
    return size_t (int64_t (level.dataWindow.max.x) - level.dataWindow.min.x + 1) *
           size_t (int64_t (level.dataWindow.max.y) - level.dataWindow.min.y + 1);
}

Part
parsePart (const Json& json, const std::string& what, bool multiPart, const std::filesystem::path& folder)
{
    expectKind (json, Json::Object, what);
    checkMembers (json, what,
                  {"type", "name", "dataWindow", "displayWindow", "compression", "lineOrder",
                   "pixelAspectRatio", "screenWindowCenter", "screenWindowWidth", "tiles",
                   "zipCompressionLevel", "dwaCompressionLevel", "zstdCompressionLevel",
                   "channels", "sampleCounts", "attributes"},
                  {"chunkCount", "levels", "chunkTableOffset", "chunkTable"});

    const Json* dataWindowJson = json.find ("dataWindow");
    if (!dataWindowJson) fail (what + " has no dataWindow");
    Box2i dataWindow    = boxFromJson (*dataWindowJson, what + ".dataWindow");
    Box2i displayWindow = dataWindow;
    if (const Json* value = json.find ("displayWindow")) displayWindow = boxFromJson (*value, what + ".displayWindow");

    float pixelAspectRatio = 1;
    if (const Json* value = json.find ("pixelAspectRatio")) pixelAspectRatio = asFloat (*value, what + ".pixelAspectRatio");
    V2f screenWindowCenter (0, 0);
    if (const Json* value = json.find ("screenWindowCenter"))
    {
        expectArray (*value, 2, what + ".screenWindowCenter");
        screenWindowCenter = V2f (asFloat (value->items[0], what + ".screenWindowCenter[0]"),
                                  asFloat (value->items[1], what + ".screenWindowCenter[1]"));
    }
    float screenWindowWidth = 1;
    if (const Json* value = json.find ("screenWindowWidth")) screenWindowWidth = asFloat (*value, what + ".screenWindowWidth");
    Imf::LineOrder lineOrder = Imf::INCREASING_Y;
    if (const Json* value = json.find ("lineOrder")) lineOrder = valueOf (lineOrderNames, *value, what + ".lineOrder");
    Imf::Compression compression = Imf::ZIP_COMPRESSION;
    if (const Json* value = json.find ("compression")) compression = valueOf (compressionNames, *value, what + ".compression");

    Part part;
    part.header = Imf::Header (displayWindow, dataWindow, pixelAspectRatio, screenWindowCenter, screenWindowWidth,
                               lineOrder, compression);

    const Json* tiles = json.find ("tiles");
    part.type         = tiles ? Imf::TILEDIMAGE : Imf::SCANLINEIMAGE;
    if (const Json* value = json.find ("type"))
    {
        part.type = asString (*value, what + ".type");
        if (part.type != Imf::SCANLINEIMAGE && part.type != Imf::TILEDIMAGE &&
            part.type != Imf::DEEPSCANLINE && part.type != Imf::DEEPTILE)
            fail (what + ".type must be scanlineimage, tiledimage, deepscanline or deeptile, not \"" + part.type + "\"");
    }
    bool isTiled = part.type == Imf::TILEDIMAGE || part.type == Imf::DEEPTILE;
    if (isTiled != (tiles != nullptr))
        fail (what + (isTiled ? " is tiled but has no \"tiles\"" : " has \"tiles\" but is not tiled"));
    if (tiles)
    {
        std::unique_ptr<Imf::Attribute> attribute = attributeFromJson ("tiledesc", *tiles, what + ".tiles");
        checkMembers (*tiles, what + ".tiles", {"xSize", "ySize", "levelMode", "roundingMode"});
        part.header.setTileDescription (static_cast<Imf::TileDescriptionAttribute&> (*attribute).value ());
    }
    if (multiPart || Imf::isDeepData (part.type)) part.header.setType (part.type);
    if (const Json* value = json.find ("name"))
        part.header.setName (asString (*value, what + ".name"));
    else if (multiPart)
        fail (what + " has no name: every part of a multi-part file needs one");

    if (const Json* value = json.find ("zipCompressionLevel"))
        part.header.zipCompressionLevel () = asInt (*value, what + ".zipCompressionLevel");
    if (const Json* value = json.find ("dwaCompressionLevel"))
        part.header.dwaCompressionLevel () = asFloat (*value, what + ".dwaCompressionLevel");
    if (const Json* value = json.find ("zstdCompressionLevel"))
        part.header.zstdCompressionLevel () = asInt (*value, what + ".zstdCompressionLevel");

    if (const Json* channels = json.find ("channels"))
    {
        expectKind (*channels, Json::Array, what + ".channels");
        for (size_t c = 0; c < channels->items.size (); c++)
        {
            const Json&       channelJson = channels->items[c];
            const std::string channelWhat = what + ".channels[" + std::to_string (c) + "]";
            expectKind (channelJson, Json::Object, channelWhat);
            checkMembers (channelJson, channelWhat, {"name", "pixelType", "xSampling", "ySampling", "pLinear", "file"});
            const Json* name = channelJson.find ("name");
            if (!name) fail (channelWhat + " has no name");
            ChannelInput input;
            input.name = asString (*name, channelWhat + ".name");
            if (const Json* value = channelJson.find ("pixelType"))
                input.channel.type = valueOf (pixelTypeNames, *value, channelWhat + ".pixelType");
            if (const Json* value = channelJson.find ("xSampling"))
                input.channel.xSampling = asInt (*value, channelWhat + ".xSampling");
            if (const Json* value = channelJson.find ("ySampling"))
                input.channel.ySampling = asInt (*value, channelWhat + ".ySampling");
            if (input.channel.xSampling < 1 || input.channel.ySampling < 1)
                fail (channelWhat + ": the sampling must be at least 1");
            if (const Json* value = channelJson.find ("pLinear"))
                input.channel.pLinear = asBool (*value, channelWhat + ".pLinear");
            if (const Json* value = channelJson.find ("file"))
                input.file = folder / std::filesystem::u8path (asString (*value, channelWhat + ".file"));
            if (part.header.channels ().findChannel (input.name))
                fail (channelWhat + ": there is already a channel \"" + input.name + "\"");
            part.header.channels ().insert (input.name, input.channel);
            part.channels.push_back (std::move (input));
        }
    }

    if (const Json* value = json.find ("sampleCounts"))
    {
        if (!Imf::isDeepData (part.type)) fail (what + " has \"sampleCounts\" but is not deep");
        part.sampleCountsFile = folder / std::filesystem::u8path (asString (*value, what + ".sampleCounts"));
    }

    if (const Json* attributes = json.find ("attributes"))
    {
        expectKind (*attributes, Json::Array, what + ".attributes");
        std::set<std::string> names;
        for (size_t a = 0; a < attributes->items.size (); a++)
        {
            const Json&       attributeJson = attributes->items[a];
            const std::string attributeWhat = what + ".attributes[" + std::to_string (a) + "]";
            expectKind (attributeJson, Json::Object, attributeWhat);
            checkMembers (attributeJson, attributeWhat, {"name", "type", "value", "data"});
            const Json* name = attributeJson.find ("name");
            const Json* type = attributeJson.find ("type");
            if (!name || !type) fail (attributeWhat + " must have a name and a type");
            const std::string& attributeName = asString (*name, attributeWhat + ".name");
            const std::string& attributeType = asString (*type, attributeWhat + ".type");
            if (attributeName.empty () || attributeType.empty ())
                fail (attributeWhat + ": the name and the type cannot be empty");
            if (isPartMember (attributeName))
                fail (attributeWhat + ": \"" + attributeName + "\" is a member of the part, not an attribute");
            if (!names.insert (attributeName).second)
                fail (attributeWhat + ": there is already an attribute \"" + attributeName + "\"");
            const Json* value = attributeJson.find ("value");
            const Json* data  = attributeJson.find ("data");
            std::unique_ptr<Imf::Attribute> attribute;
            if (value)
            {
                attribute = attributeFromJson (attributeType, *value, attributeWhat + ".value");
                if (attributeType != attribute->typeName ())
                    fail (attributeWhat + ": internal error, " + attributeType + " is " + attribute->typeName ());
            }
            else if (data)
            {
                std::vector<char> bytes = unhex (asString (*data, attributeWhat + ".data"), attributeWhat + ".data");
                attribute = std::make_unique<Imf::OpaqueAttribute> (attributeType.c_str (), long (bytes.size ()), bytes.data ());
            }
            else
                fail (attributeWhat + " must have a value or data");
            part.header.insert (attributeName, *attribute);
        }
    }

    return part;
}

// Reads the samples of every channel, and the sample counts of a deep part.
void
loadSamples (Part& part, const std::string& what)
{
    bool deep = Imf::isDeepData (part.type);
    if (deep)
    {
        size_t pixels = 0;
        for (const Level& level: part.levels)
            pixels += pixelsInLevel (level);
        if (part.sampleCountsFile.empty ())
            part.sampleCounts.assign (pixels, 0);
        else
        {
            std::vector<char> bytes = readFile (part.sampleCountsFile);
            if (bytes.size () != pixels * sizeof (uint32_t))
                fail (what + ": " + part.sampleCountsFile.string () + " has " + std::to_string (bytes.size ()) +
                      " bytes, not " + std::to_string (pixels * sizeof (uint32_t)) + " (one UINT per pixel)");
            part.sampleCounts.resize (pixels);
            std::memcpy (part.sampleCounts.data (), bytes.data (), bytes.size ());
        }
    }
    size_t totalSamples = 0;
    for (uint32_t count: part.sampleCounts)
        totalSamples += count;

    for (ChannelInput& channel: part.channels)
    {
        size_t samples = 0;
        if (deep)
            samples = totalSamples;
        else
            for (const Level& level: part.levels)
                samples += samplesInLevel (channel.channel, level);
        size_t size = samples * size_t (pixelTypeSize (channel.channel.type));
        if (channel.file.empty ())
            channel.data.assign (size, 0);
        else
        {
            channel.data = readFile (channel.file);
            if (channel.data.size () != size)
                fail (what + ": " + channel.file.string () + ", the samples of channel \"" + channel.name + "\", has " +
                      std::to_string (channel.data.size ()) + " bytes, not " + std::to_string (size));
        }
        // A pointer past the end of an empty vector is still a valid pointer.
        channel.data.reserve (channel.data.size () + 1);
    }
}

// The frame buffer of one level of a flat part; offsets[c] is where the level
// starts in the data of channel c.
Imf::FrameBuffer
flatFrameBuffer (Part& part, const Level& level, const std::vector<size_t>& offsets)
{
    Imf::FrameBuffer frameBuffer;
    for (size_t c = 0; c < part.channels.size (); c++)
    {
        const Imf::Channel& channel = part.channels[c].channel;
        SampledRange xs = sampledRange (level.dataWindow.min.x, level.dataWindow.max.x, channel.xSampling);
        SampledRange ys = sampledRange (level.dataWindow.min.y, level.dataWindow.max.y, channel.ySampling);
        size_t       sampleSize = size_t (pixelTypeSize (channel.type));
        size_t       yStride    = sampleSize * size_t (xs.count);
        char* base = part.channels[c].data.data () + offsets[c] - xs.first * int64_t (sampleSize) - ys.first * int64_t (yStride);
        frameBuffer.insert (part.channels[c].name,
                            Imf::Slice (channel.type, base, sampleSize, yStride, channel.xSampling, channel.ySampling));
    }
    return frameBuffer;
}

struct DeepLevelBuffer
{
    Imf::DeepFrameBuffer            frameBuffer;
    std::vector<std::vector<char*>> pointers;
};

// The frame buffer of one level of a deep part; pixelOffset is the index of
// its first pixel in the sample counts, sampleOffset the index of its first
// sample in the data of the channels.
void
deepFrameBuffer (Part& part, const Level& level, size_t pixelOffset, size_t sampleOffset, DeepLevelBuffer& buffer)
{
    const Box2i& window = level.dataWindow;
    int64_t      width  = int64_t (window.max.x) - window.min.x + 1;
    size_t       pixels = pixelsInLevel (level);
    int64_t      origin = int64_t (window.min.x) + int64_t (window.min.y) * width;

    char* countsBase = reinterpret_cast<char*> (part.sampleCounts.data () + pixelOffset) - origin * int64_t (sizeof (uint32_t));
    buffer.frameBuffer.insertSampleCountSlice (
        Imf::Slice (Imf::UINT, countsBase, sizeof (uint32_t), sizeof (uint32_t) * size_t (width)));

    buffer.pointers.assign (part.channels.size (), std::vector<char*> (pixels, nullptr));
    for (size_t c = 0; c < part.channels.size (); c++)
    {
        size_t sampleSize = size_t (pixelTypeSize (part.channels[c].channel.type));
        size_t offset     = sampleOffset;
        for (size_t p = 0; p < pixels; p++)
        {
            buffer.pointers[c][p] = part.channels[c].data.data () + offset * sampleSize;
            offset += part.sampleCounts[pixelOffset + p];
        }
        char* base = reinterpret_cast<char*> (buffer.pointers[c].data ()) - origin * int64_t (sizeof (char*));
        buffer.frameBuffer.insert (
            part.channels[c].name,
            Imf::DeepSlice (part.channels[c].channel.type, base, sizeof (char*), sizeof (char*) * size_t (width), sampleSize));
    }
}

struct Tile
{
    int level; // index in part.levels
    int dx;
    int dy;
};

// Every tile of every level, in a fixed pseudo-random order (xorshift32 and
// Fisher-Yates, integers only: the same on every platform).
std::vector<Tile>
shuffledTiles (const std::vector<Level>& levels, const std::function<int (int)>& numXTiles,
               const std::function<int (int)>& numYTiles)
{
    std::vector<Tile> tiles;
    for (size_t l = 0; l < levels.size (); l++)
        for (int dy = 0; dy < numYTiles (levels[l].ly); dy++)
            for (int dx = 0; dx < numXTiles (levels[l].lx); dx++)
                tiles.push_back ({int (l), dx, dy});
    uint32_t state = 0x2545F491u;
    for (size_t i = tiles.size (); i > 1; i--)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        std::swap (tiles[i - 1], tiles[state % i]);
    }
    return tiles;
}

// Where each level starts in the data of each channel, and in the sample counts.
struct LevelOffsets
{
    std::vector<std::vector<size_t>> channels;
    std::vector<size_t>              pixels;
    std::vector<size_t>              samples;
};

LevelOffsets
levelOffsets (const Part& part)
{
    bool         deep = Imf::isDeepData (part.type);
    LevelOffsets offsets;
    offsets.channels.assign (part.levels.size (), std::vector<size_t> (part.channels.size (), 0));
    offsets.pixels.assign (part.levels.size (), 0);
    offsets.samples.assign (part.levels.size (), 0);
    std::vector<size_t> next (part.channels.size (), 0);
    size_t              pixel = 0, sample = 0;
    for (size_t l = 0; l < part.levels.size (); l++)
    {
        offsets.pixels[l]  = pixel;
        offsets.samples[l] = sample;
        size_t pixels      = pixelsInLevel (part.levels[l]);
        for (size_t p = 0; p < pixels && deep; p++)
            sample += part.sampleCounts[pixel + p];
        pixel += pixels;
        for (size_t c = 0; c < part.channels.size (); c++)
        {
            offsets.channels[l][c] = next[c];
            next[c] += samplesInLevel (part.channels[c].channel, part.levels[l]) *
                       size_t (pixelTypeSize (part.channels[c].channel.type));
        }
    }
    return offsets;
}

// The output classes of a single-part file (OutputFile...) and of a part of a
// multi-part file (OutputPart...) have the same methods.

template <typename Output>
void
writeScanLines (Output& output, Part& part, const std::string& what)
{
    part.levels = levelsOf (part.header, 1, 1, nullptr);
    loadSamples (part, what);
    LevelOffsets offsets = levelOffsets (part);
    output.setFrameBuffer (flatFrameBuffer (part, part.levels[0], offsets.channels[0]));
    const Box2i& dataWindow = part.header.dataWindow ();
    output.writePixels (dataWindow.max.y - dataWindow.min.y + 1);
}

template <typename Output>
void
writeDeepScanLines (Output& output, Part& part, const std::string& what)
{
    part.levels = levelsOf (part.header, 1, 1, nullptr);
    loadSamples (part, what);
    DeepLevelBuffer buffer;
    deepFrameBuffer (part, part.levels[0], 0, 0, buffer);
    output.setFrameBuffer (buffer.frameBuffer);
    const Box2i& dataWindow = part.header.dataWindow ();
    output.writePixels (dataWindow.max.y - dataWindow.min.y + 1);
}

// frameBufferOf(l) is the frame buffer of level l.
template <typename Output, typename FrameBufferOf>
void
writeTiles (Output& output, const Part& part, FrameBufferOf frameBufferOf)
{
    if (part.header.lineOrder () == Imf::RANDOM_Y)
        for (const Tile& tile: shuffledTiles (
                 part.levels, [&] (int lx) { return output.numXTiles (lx); },
                 [&] (int ly) { return output.numYTiles (ly); }))
        {
            const Level& level = part.levels[size_t (tile.level)];
            output.setFrameBuffer (frameBufferOf (size_t (tile.level)));
            output.writeTile (tile.dx, tile.dy, level.lx, level.ly);
        }
    else
        for (size_t l = 0; l < part.levels.size (); l++)
        {
            const Level& level = part.levels[l];
            output.setFrameBuffer (frameBufferOf (l));
            output.writeTiles (0, output.numXTiles (level.lx) - 1, 0, output.numYTiles (level.ly) - 1, level.lx, level.ly);
        }
}

template <typename Output>
void
loadTiledSamples (Output& output, Part& part, const std::string& what)
{
    part.levels = levelsOf (part.header, output.numXLevels (), output.numYLevels (),
                            [&] (int lx, int ly) { return output.dataWindowForLevel (lx, ly); });
    loadSamples (part, what);
}

template <typename Output>
void
writeFlatTiles (Output& output, Part& part, const std::string& what)
{
    loadTiledSamples (output, part, what);
    LevelOffsets                  offsets = levelOffsets (part);
    std::vector<Imf::FrameBuffer> frameBuffers;
    for (size_t l = 0; l < part.levels.size (); l++)
        frameBuffers.push_back (flatFrameBuffer (part, part.levels[l], offsets.channels[l]));
    writeTiles (output, part, [&] (size_t l) -> const Imf::FrameBuffer& { return frameBuffers[l]; });
}

template <typename Output>
void
writeDeepTiles (Output& output, Part& part, const std::string& what)
{
    loadTiledSamples (output, part, what);
    LevelOffsets                 offsets = levelOffsets (part);
    std::vector<DeepLevelBuffer> buffers (part.levels.size ());
    for (size_t l = 0; l < part.levels.size (); l++)
        deepFrameBuffer (part, part.levels[l], offsets.pixels[l], offsets.samples[l], buffers[l]);
    writeTiles (output, part, [&] (size_t l) -> const Imf::DeepFrameBuffer& { return buffers[l].frameBuffer; });
}

void
writeSinglePartFile (const std::string& path, Part& part, const std::string& what)
{
    if (part.type == Imf::SCANLINEIMAGE)
    {
        Imf::OutputFile output (path.c_str (), part.header, 0);
        writeScanLines (output, part, what);
    }
    else if (part.type == Imf::TILEDIMAGE)
    {
        Imf::TiledOutputFile output (path.c_str (), part.header, 0);
        writeFlatTiles (output, part, what);
    }
    else if (part.type == Imf::DEEPSCANLINE)
    {
        Imf::DeepScanLineOutputFile output (path.c_str (), part.header, 0);
        writeDeepScanLines (output, part, what);
    }
    else
    {
        Imf::DeepTiledOutputFile output (path.c_str (), part.header, 0);
        writeDeepTiles (output, part, what);
    }
}

void
writePart (Imf::MultiPartOutputFile& file, int number, Part& part, const std::string& what)
{
    if (part.type == Imf::SCANLINEIMAGE)
    {
        Imf::OutputPart output (file, number);
        writeScanLines (output, part, what);
    }
    else if (part.type == Imf::TILEDIMAGE)
    {
        Imf::TiledOutputPart output (file, number);
        writeFlatTiles (output, part, what);
    }
    else if (part.type == Imf::DEEPSCANLINE)
    {
        Imf::DeepScanLineOutputPart output (file, number);
        writeDeepScanLines (output, part, what);
    }
    else
    {
        Imf::DeepTiledOutputPart output (file, number);
        writeDeepTiles (output, part, what);
    }
}

int
run (int argc, char* argv[])
{
    std::string description, output;
    for (int i = 1; i < argc; i++)
    {
        std::string arg = argv[i];
        if (arg == "--version")
        {
            std::cout << "exr-from-raw (OpenEXR " << EXR_RAW_TOOLS_OPENEXR_VERSION << ")\n";
            return 0;
        }
        if (arg == "-h" || arg == "--help")
        {
            std::cout << "usage: exr-from-raw <description.json> <output.exr>\n";
            return 0;
        }
        if (!arg.empty () && arg[0] == '-')
            fail ("unknown option " + arg);
        else if (description.empty ())
            description = arg;
        else if (output.empty ())
            output = arg;
        else
            fail ("too many arguments");
    }
    if (description.empty () || output.empty ()) fail ("usage: exr-from-raw <description.json> <output.exr>");

    std::filesystem::path descriptionPath (description);
    std::vector<char>     text = readFile (descriptionPath);
    Json                  root = parseJson (std::string (text.begin (), text.end ()));
    expectKind (root, Json::Object, "the description");

    std::vector<const Json*> partJsons;
    if (const Json* parts = root.find ("parts"))
    {
        checkMembers (root, "the description", {"parts"}, {"openexr", "versionField", "flags"});
        expectKind (*parts, Json::Array, "parts");
        if (parts->items.empty ()) fail ("parts is empty");
        for (const Json& part: parts->items)
            partJsons.push_back (&part);
    }
    else
        partJsons.push_back (&root);

    std::filesystem::path folder    = descriptionPath.parent_path ();
    bool                  multiPart = partJsons.size () > 1;
    std::vector<Part>        parts;
    std::vector<std::string> names;
    for (size_t p = 0; p < partJsons.size (); p++)
    {
        names.push_back (root.find ("parts") ? "parts[" + std::to_string (p) + "]" : "the part");
        parts.push_back (parsePart (*partJsons[p], names.back (), multiPart, folder));
    }

    Imf::setGlobalThreadCount (0);
    std::vector<Imf::Header> headers;
    for (const Part& part: parts)
        headers.push_back (part.header);
    try
    {
        if (multiPart)
        {
            Imf::MultiPartOutputFile file (output.c_str (), headers.data (), int (headers.size ()), false, 0);
            for (size_t p = 0; p < parts.size (); p++)
                writePart (file, int (p), parts[p], names[p]);
        }
        else
            writeSinglePartFile (output, parts[0], names[0]);
    }
    catch (...)
    {
        std::error_code ignored;
        std::filesystem::remove (output, ignored);
        throw;
    }
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
        std::cerr << "exr-from-raw: " << e.what () << "\n";
        return 2;
    }
    catch (const std::exception& e)
    {
        std::cerr << "exr-from-raw: " << e.what () << "\n";
        return 1;
    }
}
