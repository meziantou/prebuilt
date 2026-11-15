"""psd-tools, the command-line tool of the psd-tools bundle (scripts/build-psd-tools.sh).

Run by the launcher of the bundle as `python -I -B psd-tools-cli.py <arguments>`.

It reads and writes PSD and PSB files with the low-level API of psd-tools
(https://github.com/psd-tools/psd-tools), which parses and writes the sections
of a file as they are stored, without any color conversion:

    psd-tools --version
    psd-tools dump [--no-layers] <input.psd> <output-directory>
    psd-tools write <description.json> <output.psd>

dump writes header.json, the description of the file, and the samples of the
composite image (the image data section) and of each layer as raw files.
write writes a file from such a description: the description dump writes is
one write reads, and write gives a file with the same samples again.

Raw files: the samples of every pixel, row by row, the channels of a pixel
one after the other in the order of "channels"; unsigned 8-bit samples for a
depth of 8, unsigned 16-bit little-endian samples for 16, and 32-bit
little-endian floats for 32. A depth of 1 (bitmap) is one byte per pixel, the
bit as stored: 1 is black. The samples are the stored ones: CMYK samples are
inverted (255 is no ink), and the samples of an indexed image are indexes into
"palette".

Description (header.json):

    {
      "version": 1,              1 for PSD, 2 for PSB
      "width": 4, "height": 2,
      "depth": 8,                1, 8, 16 or 32
      "colorMode": "RGB",        BITMAP, GRAYSCALE, INDEXED, RGB, CMYK,
                                 MULTICHANNEL, DUOTONE or LAB
      "channels": 3,             the channels of the composite image
      "compression": "RLE",      of the composite: RAW, RLE, ZIP or
                                 ZIP_WITH_PREDICTION
      "composite": "composite.raw",   null: write fills it with white
      "hasComposite": true,      the version info resource (1057): null when
                                 there is none; false is "Maximize
                                 Compatibility" off
      "iccProfile": "icc.icc",   the ICC profile resource (1039), or null
      "palette": [[r, g, b], ...],    256 entries for INDEXED, else null
      "transparentIndex": null,  the transparency index resource (1047)
      "mergedAlpha": false,      a negative layer count: the first extra
                                 channel is the transparency of the composite
      "layerBlock": "layerInfo", where the layers are: layerInfo, or the Lr16
                                 or Lr32 block of 16 and 32-bit files, as
                                 Photoshop writes them; null without layers
      "layers": [                from the bottom one up, as in the file
        {
          "name": "Layer 1",
          "top": 0, "left": 0, "bottom": 2, "right": 4,
          "opacity": 255, "visible": true, "blendMode": "norm",
          "clipping": 0,
          "channels": [0, 1, 2, -1],   -1 is the transparency
          "compression": "RLE",        one for every channel, or a list
          "file": "layer-0.raw",       null for an empty layer
          "mask": {                    the user mask (-2), or null
            "top": 0, "left": 0, "bottom": 2, "right": 4,
            "defaultColor": 0, "compression": "RLE", "file": "layer-0-mask.raw"
          }
        }
      ]
    }

Files are relative to the folder of header.json. The other sections of the
file (other image resources, global layer mask, other tagged blocks) are not
described, and write writes none of them.
"""

import argparse
import json
import os
import sys

import numpy
import PIL
from psd_tools.constants import BlendMode, ChannelID, ColorMode, Compression, Resource, Tag
from psd_tools.psd import PSD
from psd_tools.psd.color_mode_data import ColorModeData
from psd_tools.psd.header import FileHeader
from psd_tools.psd.image_data import ImageData
from psd_tools.psd.image_resources import ImageResource, ImageResources, VersionInfo
from psd_tools.psd.layer_and_mask import (
    ChannelData,
    ChannelDataList,
    ChannelImageData,
    ChannelInfo,
    GlobalLayerMaskInfo,
    LayerAndMaskInformation,
    LayerFlags,
    LayerInfo,
    LayerInfoBlock,
    LayerRecord,
    LayerRecords,
    MaskData,
    MaskFlags,
)
from psd_tools.psd.tagged_blocks import TaggedBlock, TaggedBlocks
from psd_tools.version import __version__

def fail(message):
    print(f"psd-tools: {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Samples
# ---------------------------------------------------------------------------


def stored_dtype(depth):
    return {8: numpy.dtype("u1"), 16: numpy.dtype(">u2"), 32: numpy.dtype(">f4")}[depth]


def raw_dtype(depth):
    return {8: numpy.dtype("u1"), 16: numpy.dtype("<u2"), 32: numpy.dtype("<f4")}[depth]


def plane_to_array(data, width, height, depth):
    """A decompressed channel as a (height, width) array of the raw type."""
    if depth == 1:
        row_bytes = (width + 7) // 8
        rows = numpy.frombuffer(data, dtype="u1", count=row_bytes * height).reshape(height, row_bytes)
        return numpy.unpackbits(rows, axis=1)[:, :width]
    array = numpy.frombuffer(data, dtype=stored_dtype(depth), count=width * height)
    return array.reshape(height, width).astype(raw_dtype(depth))


def array_to_plane(array, depth):
    """A (height, width) array of the raw type as a decompressed channel."""
    if depth == 1:
        return numpy.packbits(array.astype("u1") & 1, axis=1).tobytes()
    return array.astype(stored_dtype(depth)).tobytes()


def write_raw(path, planes, depth):
    """Interleaves the channels of a pixel."""
    interleaved = numpy.stack(planes, axis=-1)
    if depth == 1:
        interleaved = interleaved.astype("u1")
    with open(path, "wb") as f:
        f.write(interleaved.tobytes())


def read_raw(path, width, height, count, depth):
    dtype = numpy.dtype("u1") if depth == 1 else raw_dtype(depth)
    with open(path, "rb") as f:
        data = f.read()
    expected = width * height * count * dtype.itemsize
    if len(data) != expected:
        fail(f"{path} has {len(data)} bytes, not {expected} ({width}x{height}, {count} channels, depth {depth})")
    array = numpy.frombuffer(data, dtype=dtype).reshape(height, width, count)
    return [array[:, :, i] for i in range(count)]


def white_planes(color_mode, count, width, height, depth):
    """The samples of a white image, as stored."""
    if depth == 1:
        value = 0
    elif depth == 32:
        value = 1.0
    else:
        value = (1 << depth) - 1
    planes = []
    for i in range(count):
        # The extra channels (alpha) are opaque; an index of 0 for INDEXED,
        # whose palette is the file's.
        if color_mode == ColorMode.INDEXED and i == 0:
            planes.append(numpy.zeros((height, width), dtype=raw_dtype(depth)))
        else:
            planes.append(numpy.full((height, width), value, dtype="u1" if depth == 1 else raw_dtype(depth)))
    return planes


def compression_name(value):
    return Compression(value).name


def parse_compression(value):
    try:
        return Compression[value]
    except KeyError:
        fail(f"unknown compression {value!r}: RAW, RLE, ZIP or ZIP_WITH_PREDICTION")


# ---------------------------------------------------------------------------
# dump
# ---------------------------------------------------------------------------


def layer_block(psd):
    tagged_blocks = psd.layer_and_mask_information.tagged_blocks
    if tagged_blocks is not None:
        for key, name in ((Tag.LAYER_16, "Lr16"), (Tag.LAYER_32, "Lr32")):
            if key in tagged_blocks:
                return tagged_blocks.get_data(key), name
    layer_info = psd.layer_and_mask_information.layer_info
    if layer_info is not None and layer_info.layer_records:
        return layer_info, "layerInfo"
    return None, None


def channel_order(channel_ids):
    """Color channels first, then the transparency, as dump writes them."""
    return sorted(channel_ids, key=lambda i: (i < 0, -i if i < 0 else i))


def dump(args):
    with open(args.input, "rb") as f:
        psd = PSD.read(f)
    header = psd.header
    os.makedirs(args.output, exist_ok=True)

    width, height, depth = header.width, header.height, header.depth
    planes = psd.image_data.get_data(header)
    write_raw(
        os.path.join(args.output, "composite.raw"),
        [plane_to_array(p, width, height, depth) for p in planes],
        depth,
    )

    resources = psd.image_resources
    icc = resources.get_data(Resource.ICC_PROFILE)
    icc_file = None
    if icc is not None:
        icc_file = "icc.icc"
        with open(os.path.join(args.output, icc_file), "wb") as f:
            f.write(bytes(icc))

    version_info = resources.get_data(Resource.VERSION_INFO)
    has_composite = None if version_info is None else bool(version_info.has_composite)
    transparent_index = resources.get_data(Resource.TRANSPARENCY_INDEX)

    palette = None
    if header.color_mode == ColorMode.INDEXED:
        value = bytes(psd.color_mode_data.value)
        if len(value) >= 768:
            palette = [[value[i], value[256 + i], value[512 + i]] for i in range(256)]

    description = {
        "psdTools": __version__,
        "version": header.version,
        "width": width,
        "height": height,
        "depth": depth,
        "colorMode": ColorMode(header.color_mode).name,
        "channels": header.channels,
        "compression": compression_name(psd.image_data.compression),
        "composite": "composite.raw",
        "hasComposite": has_composite,
        "iccProfile": icc_file,
        "palette": palette,
        "transparentIndex": None if transparent_index is None else int(transparent_index),
        "mergedAlpha": False,
        "layerBlock": None,
        "layers": [],
    }

    info, block = layer_block(psd)
    if info is not None:
        description["mergedAlpha"] = info.layer_count < 0
        description["layerBlock"] = block
    if info is not None and not args.no_layers:
        for index, (record, channels) in enumerate(zip(info.layer_records, info.channel_image_data, strict=True)):
            description["layers"].append(dump_layer(args.output, index, record, channels, header))

    with open(os.path.join(args.output, "header.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(to_json(description))


def to_json(value, indent=""):
    """Indented JSON, with the lists of numbers (channels, palette entries) on one line."""
    inner = indent + "  "
    if isinstance(value, dict) and value:
        items = [f"{inner}{json.dumps(k)}: {to_json(v, inner).lstrip()}" for k, v in value.items()]
        return indent + "{\n" + ",\n".join(items) + "\n" + indent + "}" + ("\n" if not indent else "")
    if isinstance(value, list) and value and not all(isinstance(v, (int, float)) for v in value):
        items = [to_json(v, inner) for v in value]
        return indent + "[\n" + ",\n".join(items) + "\n" + indent + "]"
    return indent + json.dumps(value)


def dump_layer(output, index, record, channels, header):
    depth = header.depth
    width = record.right - record.left
    height = record.bottom - record.top
    data = {int(info.id): (info, channel) for info, channel in zip(record.channel_info, channels, strict=True)}
    color_ids = channel_order([i for i in data if i >= -1])

    layer = {
        "name": record.name,
        "top": record.top,
        "left": record.left,
        "bottom": record.bottom,
        "right": record.right,
        "opacity": record.opacity,
        "visible": bool(record.flags.visible),
        "blendMode": BlendMode(record.blend_mode).value.decode("ascii"),
        "clipping": int(record.clipping),
        "channels": color_ids,
        "compression": None,
        "file": None,
        "mask": None,
    }

    compressions = [compression_name(data[i][1].compression) for i in color_ids]
    layer["compression"] = compressions[0] if len(set(compressions)) == 1 else compressions
    if width > 0 and height > 0 and color_ids:
        name = f"layer-{index}.raw"
        planes = [plane_to_array(data[i][1].get_data(width, height, depth, header.version), width, height, depth) for i in color_ids]
        write_raw(os.path.join(output, name), planes, depth)
        layer["file"] = name

    mask = record.mask_data
    if ChannelID.USER_LAYER_MASK in data and mask is not None:
        mask_width = mask.right - mask.left
        mask_height = mask.bottom - mask.top
        channel = data[ChannelID.USER_LAYER_MASK][1]
        layer["mask"] = {
            "top": mask.top,
            "left": mask.left,
            "bottom": mask.bottom,
            "right": mask.right,
            "defaultColor": mask.background_color,
            "compression": compression_name(channel.compression),
            "file": None,
        }
        if mask_width > 0 and mask_height > 0:
            name = f"layer-{index}-mask.raw"
            plane = plane_to_array(channel.get_data(mask_width, mask_height, depth, header.version), mask_width, mask_height, depth)
            write_raw(os.path.join(output, name), [plane], depth)
            layer["mask"]["file"] = name
    return layer


# ---------------------------------------------------------------------------
# write
# ---------------------------------------------------------------------------


def write(args):
    with open(args.description, encoding="utf-8") as f:
        description = json.load(f)
    base = os.path.dirname(os.path.abspath(args.description))

    def path(name):
        return os.path.join(base, name)

    try:
        color_mode = ColorMode[description["colorMode"]]
    except KeyError:
        fail(f"unknown color mode {description['colorMode']!r}")
    version = description.get("version", 1)
    width, height, depth = description["width"], description["height"], description["depth"]
    channels = description["channels"]
    header = FileHeader(
        version=version, channels=channels, height=height, width=width, depth=depth, color_mode=color_mode
    )

    color_mode_data = ColorModeData()
    palette = description.get("palette")
    if palette is not None:
        if len(palette) > 256:
            fail("a palette has 256 colors at most")
        entries = list(palette) + [[0, 0, 0]] * (256 - len(palette))
        color_mode_data = ColorModeData(value=bytes([e[0] for e in entries] + [e[1] for e in entries] + [e[2] for e in entries]))

    resources = []
    has_composite = description.get("hasComposite", True)
    if has_composite is not None:
        resources.append(
            (
                Resource.VERSION_INFO,
                ImageResource(
                    key=Resource.VERSION_INFO,
                    data=VersionInfo(has_composite=bool(has_composite), writer=f"psd-tools {__version__}", reader=f"psd-tools {__version__}"),
                ),
            )
        )
    if description.get("iccProfile"):
        with open(path(description["iccProfile"]), "rb") as f:
            resources.append((Resource.ICC_PROFILE, ImageResource(key=Resource.ICC_PROFILE, data=f.read())))
    if description.get("transparentIndex") is not None:
        value = int(description["transparentIndex"]).to_bytes(2, "big")
        resources.append((Resource.TRANSPARENCY_INDEX, ImageResource(key=Resource.TRANSPARENCY_INDEX, data=value)))
    image_resources = ImageResources(resources)

    layers = description.get("layers") or []
    layer_info = LayerInfo()
    tagged_blocks = TaggedBlocks()
    if layers:
        records = LayerRecords()
        channel_image_data = ChannelImageData()
        for layer in layers:
            record, channel_list = make_layer(layer, depth, version, path)
            records.append(record)
            channel_image_data.append(channel_list)
        count = len(layers) * (-1 if description.get("mergedAlpha") else 1)
        block = description.get("layerBlock") or ("layerInfo" if depth <= 8 else f"Lr{depth}")
        if block == "layerInfo":
            layer_info = LayerInfo(layer_count=count, layer_records=records, channel_image_data=channel_image_data)
        elif block in ("Lr16", "Lr32"):
            key = Tag.LAYER_16 if block == "Lr16" else Tag.LAYER_32
            info = LayerInfoBlock(layer_count=count, layer_records=records, channel_image_data=channel_image_data)
            tagged_blocks[key] = TaggedBlock(key=key, data=info)
        else:
            fail(f"unknown layer block {block!r}: layerInfo, Lr16 or Lr32")

    composite = description.get("composite")
    if composite:
        planes = read_raw(path(composite), width, height, channels, depth)
    else:
        planes = white_planes(color_mode, channels, width, height, depth)
    image_data = ImageData(compression=parse_compression(description.get("compression", "RAW")))
    image_data.set_data([array_to_plane(p, depth) for p in planes], header)

    psd = PSD(
        header=header,
        color_mode_data=color_mode_data,
        image_resources=image_resources,
        # Photoshop writes an empty global layer mask info before the Lr16 and
        # Lr32 blocks, and some readers (ImageMagick) do not find them without.
        layer_and_mask_information=LayerAndMaskInformation(
            layer_info=layer_info,
            global_layer_mask_info=GlobalLayerMaskInfo() if len(tagged_blocks) else None,
            tagged_blocks=tagged_blocks if len(tagged_blocks) else None,
        ),
        image_data=image_data,
    )
    with open(args.output, "wb") as f:
        psd.write(f)


def make_layer(layer, depth, version, path):
    top, left, bottom, right = layer["top"], layer["left"], layer["bottom"], layer["right"]
    width, height = right - left, bottom - top
    ids = [int(i) for i in layer["channels"]]
    compression = layer.get("compression", "RLE")
    compressions = compression if isinstance(compression, list) else [compression] * len(ids)
    if len(compressions) != len(ids):
        fail(f"layer {layer.get('name', '')!r}: {len(compressions)} compressions for {len(ids)} channels")

    if layer.get("file") and width > 0 and height > 0:
        planes = read_raw(path(layer["file"]), width, height, len(ids), depth)
    else:
        planes = [numpy.zeros((max(height, 0), max(width, 0)), dtype="u1" if depth == 1 else raw_dtype(depth)) for _ in ids]

    channel_info = []
    channel_list = ChannelDataList()
    for channel_id, plane, name in zip(ids, planes, compressions, strict=True):
        data = ChannelData(compression=parse_compression(name))
        if width > 0 and height > 0:
            data.set_data(array_to_plane(plane, depth), width, height, depth, version)
        channel_info.append(ChannelInfo(id=ChannelID(channel_id), length=0))
        channel_list.append(data)

    mask_data = None
    mask = layer.get("mask")
    if mask:
        mask_width = mask["right"] - mask["left"]
        mask_height = mask["bottom"] - mask["top"]
        data = ChannelData(compression=parse_compression(mask.get("compression", "RLE")))
        if mask.get("file") and mask_width > 0 and mask_height > 0:
            (plane,) = read_raw(path(mask["file"]), mask_width, mask_height, 1, depth)
            data.set_data(array_to_plane(plane, depth), mask_width, mask_height, depth, version)
        channel_info.append(ChannelInfo(id=ChannelID.USER_LAYER_MASK, length=0))
        channel_list.append(data)
        mask_data = MaskData(
            top=mask["top"],
            left=mask["left"],
            bottom=mask["bottom"],
            right=mask["right"],
            background_color=mask.get("defaultColor", 0),
            flags=MaskFlags(),
        )

    record = LayerRecord(
        top=top,
        left=left,
        bottom=bottom,
        right=right,
        channel_info=channel_info,
        blend_mode=BlendMode(layer.get("blendMode", "norm").encode("ascii")),
        opacity=layer.get("opacity", 255),
        clipping=layer.get("clipping", 0),
        flags=LayerFlags(visible=layer.get("visible", True)),
        mask_data=mask_data,
        name=layer.get("name", ""),
    )
    return record, channel_list


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def version_string():
    python = ".".join(str(v) for v in sys.version_info[:3])
    return f"psd-tools {__version__} (Python {python}, numpy {numpy.__version__}, Pillow {PIL.__version__})"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="psd-tools", description="Reads and writes the samples of PSD and PSB files.")
    parser.add_argument("--version", action="version", version=version_string())
    subparsers = parser.add_subparsers(dest="command", required=True)

    dump_parser = subparsers.add_parser("dump", help="write the description and the samples of a file")
    dump_parser.add_argument("--no-layers", action="store_true", help="the composite image only")
    dump_parser.add_argument("input")
    dump_parser.add_argument("output", help="output directory")

    write_parser = subparsers.add_parser("write", help="write a file from a description")
    write_parser.add_argument("description", help="header.json")
    write_parser.add_argument("output")

    args = parser.parse_args(argv)
    if args.command == "dump":
        dump(args)
    else:
        write(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
