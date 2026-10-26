// Shared by exr-from-raw.cpp and exr-to-raw.cpp (see scripts/build-openexr.sh):
// a small JSON reader and writer, the names of the OpenEXR enumerations, and
// the conversion of header attributes to and from JSON.
//
// The JSON format is described at the top of exr-from-raw.cpp and in
// src/Meziantou.Prebuilt/README.md.

#ifndef EXR_RAW_COMMON_H
#define EXR_RAW_COMMON_H

#include <ImfAttribute.h>
#include <ImfBoxAttribute.h>
#include <ImfChannelList.h>
#include <ImfChromaticitiesAttribute.h>
#include <ImfCompression.h>
#include <ImfCompressionAttribute.h>
#include <ImfDeepImageStateAttribute.h>
#include <ImfDoubleAttribute.h>
#include <ImfEnvmapAttribute.h>
#include <ImfFloatAttribute.h>
#include <ImfFloatVectorAttribute.h>
#include <ImfHeader.h>
#include <ImfIO.h>
#include <ImfIntAttribute.h>
#include <ImfKeyCodeAttribute.h>
#include <ImfLineOrderAttribute.h>
#include <ImfMatrixAttribute.h>
#include <ImfOpaqueAttribute.h>
#include <ImfPartType.h>
#include <ImfPixelType.h>
#include <ImfPreviewImageAttribute.h>
#include <ImfRationalAttribute.h>
#include <ImfStringAttribute.h>
#include <ImfStringVectorAttribute.h>
#include <ImfTileDescriptionAttribute.h>
#include <ImfTimeCodeAttribute.h>
#include <ImfVecAttribute.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace exrraw
{

namespace Imf = OPENEXR_IMF_NAMESPACE;

// Not an OpenEXR error: a problem of the command line or of the description.
struct UsageError : std::runtime_error
{
    explicit UsageError (const std::string& message) : std::runtime_error (message) {}
};

[[noreturn]] inline void
fail (const std::string& message)
{
    throw UsageError (message);
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

struct Json
{
    enum Kind
    {
        Null,
        Bool,
        Number,
        String,
        Array,
        Object
    };

    Kind        kind    = Null;
    bool        boolean = false;
    std::string text; // the string, or the literal of the number
    std::vector<Json>                         items;
    std::vector<std::pair<std::string, Json>> members;

    const Json* find (const std::string& key) const
    {
        for (const auto& member: members)
            if (member.first == key) return &member.second;
        return nullptr;
    }
};

class JsonParser
{
public:
    explicit JsonParser (const std::string& text) : _text (text) {}

    Json parseDocument ()
    {
        Json value = parseValue (0);
        skipWhitespace ();
        if (_position != _text.size ()) error ("unexpected text after the value");
        return value;
    }

private:
    const std::string& _text;
    size_t             _position = 0;

    [[noreturn]] void error (const std::string& message) const
    {
        fail ("invalid JSON at offset " + std::to_string (_position) + ": " + message);
    }

    void skipWhitespace ()
    {
        while (_position < _text.size () &&
               (_text[_position] == ' ' || _text[_position] == '\t' ||
                _text[_position] == '\n' || _text[_position] == '\r'))
            _position++;
    }

    bool consume (const char* literal)
    {
        size_t length = std::strlen (literal);
        if (_text.compare (_position, length, literal) != 0) return false;
        _position += length;
        return true;
    }

    Json parseValue (int depth)
    {
        if (depth > 64) error ("too deeply nested");
        skipWhitespace ();
        if (_position >= _text.size ()) error ("unexpected end");
        Json value;
        char c = _text[_position];
        if (c == '{')
        {
            value.kind = Json::Object;
            _position++;
            skipWhitespace ();
            if (_position < _text.size () && _text[_position] == '}')
            {
                _position++;
                return value;
            }
            for (;;)
            {
                skipWhitespace ();
                if (_position >= _text.size () || _text[_position] != '"')
                    error ("expected a member name");
                std::string key = parseString ();
                if (value.find (key)) error ("duplicate member \"" + key + "\"");
                skipWhitespace ();
                if (!consume (":")) error ("expected ':'");
                Json member = parseValue (depth + 1);
                value.members.emplace_back (std::move (key), std::move (member));
                skipWhitespace ();
                if (consume ("}")) return value;
                if (!consume (",")) error ("expected ',' or '}'");
            }
        }
        if (c == '[')
        {
            value.kind = Json::Array;
            _position++;
            skipWhitespace ();
            if (_position < _text.size () && _text[_position] == ']')
            {
                _position++;
                return value;
            }
            for (;;)
            {
                value.items.push_back (parseValue (depth + 1));
                skipWhitespace ();
                if (consume ("]")) return value;
                if (!consume (",")) error ("expected ',' or ']'");
            }
        }
        if (c == '"')
        {
            value.kind = Json::String;
            value.text = parseString ();
            return value;
        }
        if (consume ("true"))
        {
            value.kind    = Json::Bool;
            value.boolean = true;
            return value;
        }
        if (consume ("false"))
        {
            value.kind = Json::Bool;
            return value;
        }
        if (consume ("null")) return value;
        if (c == '-' || (c >= '0' && c <= '9'))
        {
            size_t start = _position;
            if (_text[_position] == '-') _position++;
            if (_position >= _text.size () || !isDigit (_text[_position]))
                error ("invalid number");
            if (_text[_position] == '0')
                _position++;
            else
                while (_position < _text.size () && isDigit (_text[_position]))
                    _position++;
            if (_position < _text.size () && _text[_position] == '.')
            {
                _position++;
                if (_position >= _text.size () || !isDigit (_text[_position]))
                    error ("invalid number");
                while (_position < _text.size () && isDigit (_text[_position]))
                    _position++;
            }
            if (_position < _text.size () &&
                (_text[_position] == 'e' || _text[_position] == 'E'))
            {
                _position++;
                if (_position < _text.size () &&
                    (_text[_position] == '+' || _text[_position] == '-'))
                    _position++;
                if (_position >= _text.size () || !isDigit (_text[_position]))
                    error ("invalid number");
                while (_position < _text.size () && isDigit (_text[_position]))
                    _position++;
            }
            value.kind = Json::Number;
            value.text = _text.substr (start, _position - start);
            return value;
        }
        error ("unexpected character");
    }

    static bool isDigit (char c) { return c >= '0' && c <= '9'; }

    unsigned parseHex4 ()
    {
        if (_position + 4 > _text.size ()) error ("truncated \\u escape");
        unsigned value = 0;
        for (int i = 0; i < 4; i++)
        {
            char c = _text[_position++];
            value <<= 4;
            if (c >= '0' && c <= '9')
                value |= unsigned (c - '0');
            else if (c >= 'a' && c <= 'f')
                value |= unsigned (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F')
                value |= unsigned (c - 'A' + 10);
            else
                error ("invalid \\u escape");
        }
        return value;
    }

    static void appendUtf8 (std::string& out, unsigned code)
    {
        if (code < 0x80)
            out += char (code);
        else if (code < 0x800)
        {
            out += char (0xC0 | (code >> 6));
            out += char (0x80 | (code & 0x3F));
        }
        else if (code < 0x10000)
        {
            out += char (0xE0 | (code >> 12));
            out += char (0x80 | ((code >> 6) & 0x3F));
            out += char (0x80 | (code & 0x3F));
        }
        else
        {
            out += char (0xF0 | (code >> 18));
            out += char (0x80 | ((code >> 12) & 0x3F));
            out += char (0x80 | ((code >> 6) & 0x3F));
            out += char (0x80 | (code & 0x3F));
        }
    }

    std::string parseString ()
    {
        _position++; // the opening quote
        std::string out;
        for (;;)
        {
            if (_position >= _text.size ()) error ("unterminated string");
            char c = _text[_position++];
            if (c == '"') return out;
            if (static_cast<unsigned char> (c) < 0x20)
                error ("control character in a string");
            if (c != '\\')
            {
                out += c;
                continue;
            }
            if (_position >= _text.size ()) error ("unterminated string");
            char escape = _text[_position++];
            switch (escape)
            {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    unsigned code = parseHex4 ();
                    if (code >= 0xD800 && code <= 0xDBFF)
                    {
                        if (!consume ("\\u")) error ("lone high surrogate");
                        unsigned low = parseHex4 ();
                        if (low < 0xDC00 || low > 0xDFFF)
                            error ("invalid low surrogate");
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    }
                    else if (code >= 0xDC00 && code <= 0xDFFF)
                        error ("lone low surrogate");
                    appendUtf8 (out, code);
                    break;
                }
                default: error ("invalid escape");
            }
        }
    }
};

inline Json
parseJson (const std::string& text)
{
    return JsonParser (text).parseDocument ();
}

// Typed accessors. `what` names the value in the error messages.

inline const Json&
expectKind (const Json& value, Json::Kind kind, const std::string& what)
{
    static const char* names[] = {"null", "a boolean", "a number", "a string", "an array", "an object"};
    if (value.kind != kind)
        fail (what + " must be " + names[kind] + ", not " + names[value.kind]);
    return value;
}

inline const Json&
expectArray (const Json& value, size_t count, const std::string& what)
{
    expectKind (value, Json::Array, what);
    if (value.items.size () != count)
        fail (what + " must have " + std::to_string (count) + " items, not " +
              std::to_string (value.items.size ()));
    return value;
}

inline int64_t
asInteger (const Json& value, const std::string& what, int64_t min, int64_t max)
{
    expectKind (value, Json::Number, what);
    const std::string& text = value.text;
    if (text.find_first_of (".eE") != std::string::npos)
        fail (what + " must be an integer, not " + text);
    errno          = 0;
    char*     end  = nullptr;
    long long parsed = std::strtoll (text.c_str (), &end, 10);
    if (errno != 0 || *end != '\0' || parsed < min || parsed > max)
        fail (what + " is out of range: " + text);
    return parsed;
}

inline int
asInt (const Json& value, const std::string& what)
{
    return int (asInteger (value, what, std::numeric_limits<int>::min (), std::numeric_limits<int>::max ()));
}

inline unsigned
asUnsigned (const Json& value, const std::string& what)
{
    return unsigned (asInteger (value, what, 0, std::numeric_limits<unsigned>::max ()));
}

inline bool
asBool (const Json& value, const std::string& what)
{
    return expectKind (value, Json::Bool, what).boolean;
}

inline const std::string&
asString (const Json& value, const std::string& what)
{
    return expectKind (value, Json::String, what).text;
}

// A number, or "NaN", "Infinity" or "-Infinity", which JSON has no number for.
// strtod and strtof round correctly, so a value written by exr-to-raw is read
// back exactly.
inline double
asDouble (const Json& value, const std::string& what)
{
    if (value.kind == Json::String)
    {
        if (value.text == "NaN") return std::numeric_limits<double>::quiet_NaN ();
        if (value.text == "Infinity") return std::numeric_limits<double>::infinity ();
        if (value.text == "-Infinity") return -std::numeric_limits<double>::infinity ();
        fail (what + " must be a number, \"NaN\", \"Infinity\" or \"-Infinity\", not \"" + value.text + "\"");
    }
    expectKind (value, Json::Number, what);
    return std::strtod (value.text.c_str (), nullptr);
}

inline float
asFloat (const Json& value, const std::string& what)
{
    if (value.kind == Json::String) return float (asDouble (value, what));
    expectKind (value, Json::Number, what);
    return std::strtof (value.text.c_str (), nullptr);
}

// --- Writing

inline std::string
jsonString (const std::string& text)
{
    // Invalid UTF-8 cannot be written in JSON: each invalid byte becomes
    // U+FFFD. The "data" of an attribute has its exact bytes.
    std::string out = "\"";
    size_t      i   = 0;
    while (i < text.size ())
    {
        unsigned char c = static_cast<unsigned char> (text[i]);
        if (c < 0x80)
        {
            switch (c)
            {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20 || c == 0x7F)
                    {
                        char buffer[8];
                        std::snprintf (buffer, sizeof (buffer), "\\u%04x", c);
                        out += buffer;
                    }
                    else
                        out += char (c);
            }
            i++;
            continue;
        }
        size_t   length = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 0;
        unsigned code   = length == 4 ? c & 0x07 : length == 3 ? c & 0x0F : c & 0x1F;
        bool     valid  = length != 0 && i + length <= text.size ();
        for (size_t k = 1; valid && k < length; k++)
        {
            unsigned char next = static_cast<unsigned char> (text[i + k]);
            if ((next & 0xC0) != 0x80)
                valid = false;
            else
                code = (code << 6) | (next & 0x3F);
        }
        if (valid)
        {
            unsigned minimum = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000;
            valid = code >= minimum && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF);
        }
        if (valid)
        {
            out.append (text, i, length);
            i += length;
        }
        else
        {
            out += "\\ufffd";
            i++;
        }
    }
    out += '"';
    return out;
}

// The shortest decimal that strtof/strtod read back as the same value.
inline std::string
jsonFloat (float value)
{
    if (std::isnan (value)) return "\"NaN\"";
    if (std::isinf (value)) return value > 0 ? "\"Infinity\"" : "\"-Infinity\"";
    char buffer[64];
    for (int precision = 1; precision <= 9; precision++)
    {
        std::snprintf (buffer, sizeof (buffer), "%.*g", precision, double (value));
        if (std::strtof (buffer, nullptr) == value) break;
    }
    return buffer;
}

inline std::string
jsonDouble (double value)
{
    if (std::isnan (value)) return "\"NaN\"";
    if (std::isinf (value)) return value > 0 ? "\"Infinity\"" : "\"-Infinity\"";
    char buffer[64];
    for (int precision = 1; precision <= 17; precision++)
    {
        std::snprintf (buffer, sizeof (buffer), "%.*g", precision, value);
        if (std::strtod (buffer, nullptr) == value) break;
    }
    return buffer;
}

inline std::string
hex (const void* data, size_t size)
{
    static const char digits[] = "0123456789abcdef";
    std::string       out;
    out.reserve (size * 2);
    const unsigned char* bytes = static_cast<const unsigned char*> (data);
    for (size_t i = 0; i < size; i++)
    {
        out += digits[bytes[i] >> 4];
        out += digits[bytes[i] & 15];
    }
    return out;
}

inline std::vector<char>
unhex (const std::string& text, const std::string& what)
{
    if (text.size () % 2 != 0) fail (what + " must have an even number of hexadecimal digits");
    std::vector<char> out (text.size () / 2);
    for (size_t i = 0; i < out.size (); i++)
    {
        int value = 0;
        for (int k = 0; k < 2; k++)
        {
            char c = text[2 * i + k];
            value <<= 4;
            if (c >= '0' && c <= '9')
                value |= c - '0';
            else if (c >= 'a' && c <= 'f')
                value |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                value |= c - 'A' + 10;
            else
                fail (what + " is not hexadecimal");
        }
        out[i] = char (value);
    }
    return out;
}

// A JSON array of already formatted values.
inline std::string
jsonList (const std::vector<std::string>& values)
{
    std::string out = "[";
    for (size_t i = 0; i < values.size (); i++)
    {
        if (i) out += ", ";
        out += values[i];
    }
    return out + "]";
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

template <typename T> struct NamedValue
{
    T           value;
    const char* name;
};

static const NamedValue<Imf::Compression> compressionNames[] = {
    {Imf::NO_COMPRESSION, "NONE"},
    {Imf::RLE_COMPRESSION, "RLE"},
    {Imf::ZIPS_COMPRESSION, "ZIPS"},
    {Imf::ZIP_COMPRESSION, "ZIP"},
    {Imf::PIZ_COMPRESSION, "PIZ"},
    {Imf::PXR24_COMPRESSION, "PXR24"},
    {Imf::B44_COMPRESSION, "B44"},
    {Imf::B44A_COMPRESSION, "B44A"},
    {Imf::DWAA_COMPRESSION, "DWAA"},
    {Imf::DWAB_COMPRESSION, "DWAB"},
    {Imf::HTJ2K256_COMPRESSION, "HTJ2K256"},
    {Imf::HTJ2K32_COMPRESSION, "HTJ2K32"},
    {Imf::LJ2K_COMPRESSION, "LJ2K"},
    {Imf::ZSTD_COMPRESSION, "ZSTD"},
};

static const NamedValue<Imf::LineOrder> lineOrderNames[] = {
    {Imf::INCREASING_Y, "INCREASING_Y"},
    {Imf::DECREASING_Y, "DECREASING_Y"},
    {Imf::RANDOM_Y, "RANDOM_Y"},
};

static const NamedValue<Imf::PixelType> pixelTypeNames[] = {
    {Imf::UINT, "UINT"},
    {Imf::HALF, "HALF"},
    {Imf::FLOAT, "FLOAT"},
};

static const NamedValue<Imf::LevelMode> levelModeNames[] = {
    {Imf::ONE_LEVEL, "ONE_LEVEL"},
    {Imf::MIPMAP_LEVELS, "MIPMAP_LEVELS"},
    {Imf::RIPMAP_LEVELS, "RIPMAP_LEVELS"},
};

static const NamedValue<Imf::LevelRoundingMode> roundingModeNames[] = {
    {Imf::ROUND_DOWN, "ROUND_DOWN"},
    {Imf::ROUND_UP, "ROUND_UP"},
};

static const NamedValue<Imf::Envmap> envmapNames[] = {
    {Imf::ENVMAP_LATLONG, "LATLONG"},
    {Imf::ENVMAP_CUBE, "CUBE"},
};

static const NamedValue<Imf::DeepImageState> deepImageStateNames[] = {
    {Imf::DIS_MESSY, "MESSY"},
    {Imf::DIS_SORTED, "SORTED"},
    {Imf::DIS_NON_OVERLAPPING, "NON_OVERLAPPING"},
    {Imf::DIS_TIDY, "TIDY"},
};

template <typename T, size_t N>
std::string
nameOf (const NamedValue<T> (&names)[N], T value)
{
    for (const auto& entry: names)
        if (entry.value == value) return entry.name;
    return std::to_string (int (value));
}

template <typename T, size_t N>
T
valueOf (const NamedValue<T> (&names)[N], const Json& json, const std::string& what)
{
    const std::string& name = asString (json, what);
    std::string        known;
    for (const auto& entry: names)
    {
        if (name == entry.name) return entry.value;
        known += known.empty () ? "" : ", ";
        known += entry.name;
    }
    fail (what + " must be one of " + known + ", not \"" + name + "\"");
}

inline int
pixelTypeSize (Imf::PixelType type)
{
    return type == Imf::HALF ? 2 : 4;
}

// ---------------------------------------------------------------------------
// Attributes
// ---------------------------------------------------------------------------

// The attributes of a header that are written as members of the part, not in
// its "attributes" list.
inline bool
isPartMember (const std::string& name)
{
    static const char* names[] = {
        "channels", "compression", "dataWindow", "displayWindow", "lineOrder",
        "pixelAspectRatio", "screenWindowCenter", "screenWindowWidth",
        "tiles", "name", "type", "chunkCount"};
    for (const char* member: names)
        if (name == member) return true;
    return false;
}

class MemoryOStream : public Imf::OStream
{
public:
    MemoryOStream () : Imf::OStream ("memory") {}
    void write (const char c[], int n) override
    {
        if (_position + size_t (n) > _data.size ()) _data.resize (_position + size_t (n));
        std::memcpy (_data.data () + _position, c, size_t (n));
        _position += size_t (n);
    }
    uint64_t tellp () override { return _position; }
    void     seekp (uint64_t position) override { _position = size_t (position); }
    const std::vector<char>& data () const { return _data; }

private:
    std::vector<char> _data;
    size_t            _position = 0;
};

// The bytes of the value of an attribute, as they are in the file.
inline std::vector<char>
attributeBytes (const Imf::Attribute& attribute)
{
    MemoryOStream stream;
    attribute.writeValueTo (stream, 2);
    return stream.data ();
}

inline std::string
jsonBox (const IMATH_NAMESPACE::Box2i& box)
{
    return jsonList (
        {std::to_string (box.min.x), std::to_string (box.min.y),
         std::to_string (box.max.x), std::to_string (box.max.y)});
}

inline IMATH_NAMESPACE::Box2i
boxFromJson (const Json& json, const std::string& what)
{
    expectArray (json, 4, what + " ([xMin, yMin, xMax, yMax])");
    return IMATH_NAMESPACE::Box2i (
        IMATH_NAMESPACE::V2i (asInt (json.items[0], what + "[0]"), asInt (json.items[1], what + "[1]")),
        IMATH_NAMESPACE::V2i (asInt (json.items[2], what + "[2]"), asInt (json.items[3], what + "[3]")));
}

template <typename T>
const T*
typed (const Imf::Attribute& attribute)
{
    return dynamic_cast<const T*> (&attribute);
}

template <typename M>
std::string
jsonMatrix (const M& matrix, int size, bool isDouble)
{
    std::vector<std::string> values;
    for (int i = 0; i < size; i++)
        for (int j = 0; j < size; j++)
            values.push_back (isDouble ? jsonDouble (double (matrix[i][j])) : jsonFloat (float (matrix[i][j])));
    return jsonList (values);
}

// The JSON of the value of an attribute of a known type, or an empty string.
inline std::string
attributeValueJson (const Imf::Attribute& attribute)
{
    using namespace IMATH_NAMESPACE;
    if (auto a = typed<Imf::Box2iAttribute> (attribute)) return jsonBox (a->value ());
    if (auto a = typed<Imf::Box2fAttribute> (attribute))
        return jsonList ({jsonFloat (a->value ().min.x), jsonFloat (a->value ().min.y),
                          jsonFloat (a->value ().max.x), jsonFloat (a->value ().max.y)});
    if (auto a = typed<Imf::ChromaticitiesAttribute> (attribute))
    {
        const Imf::Chromaticities& c = a->value ();
        return jsonList ({jsonFloat (c.red.x), jsonFloat (c.red.y), jsonFloat (c.green.x), jsonFloat (c.green.y),
                          jsonFloat (c.blue.x), jsonFloat (c.blue.y), jsonFloat (c.white.x), jsonFloat (c.white.y)});
    }
    if (auto a = typed<Imf::CompressionAttribute> (attribute))
        return jsonString (nameOf (compressionNames, a->value ()));
    if (auto a = typed<Imf::DoubleAttribute> (attribute)) return jsonDouble (a->value ());
    if (auto a = typed<Imf::FloatAttribute> (attribute)) return jsonFloat (a->value ());
    if (auto a = typed<Imf::IntAttribute> (attribute)) return std::to_string (a->value ());
    if (auto a = typed<Imf::EnvmapAttribute> (attribute))
        return jsonString (nameOf (envmapNames, a->value ()));
    if (auto a = typed<Imf::DeepImageStateAttribute> (attribute))
        return jsonString (nameOf (deepImageStateNames, a->value ()));
    if (auto a = typed<Imf::LineOrderAttribute> (attribute))
        return jsonString (nameOf (lineOrderNames, a->value ()));
    if (auto a = typed<Imf::FloatVectorAttribute> (attribute))
    {
        std::vector<std::string> values;
        for (float value: a->value ())
            values.push_back (jsonFloat (value));
        return jsonList (values);
    }
    if (auto a = typed<Imf::KeyCodeAttribute> (attribute))
    {
        const Imf::KeyCode& k = a->value ();
        return jsonList ({std::to_string (k.filmMfcCode ()), std::to_string (k.filmType ()),
                          std::to_string (k.prefix ()), std::to_string (k.count ()),
                          std::to_string (k.perfOffset ()), std::to_string (k.perfsPerFrame ()),
                          std::to_string (k.perfsPerCount ())});
    }
    if (auto a = typed<Imf::M33fAttribute> (attribute)) return jsonMatrix (a->value (), 3, false);
    if (auto a = typed<Imf::M33dAttribute> (attribute)) return jsonMatrix (a->value (), 3, true);
    if (auto a = typed<Imf::M44fAttribute> (attribute)) return jsonMatrix (a->value (), 4, false);
    if (auto a = typed<Imf::M44dAttribute> (attribute)) return jsonMatrix (a->value (), 4, true);
    if (auto a = typed<Imf::PreviewImageAttribute> (attribute))
    {
        const Imf::PreviewImage& p = a->value ();
        return "{\"width\": " + std::to_string (p.width ()) + ", \"height\": " + std::to_string (p.height ()) +
               ", \"pixels\": \"" + hex (p.pixels (), size_t (p.width ()) * p.height () * 4) + "\"}";
    }
    if (auto a = typed<Imf::RationalAttribute> (attribute))
        return jsonList ({std::to_string (a->value ().n), std::to_string (a->value ().d)});
    if (auto a = typed<Imf::StringAttribute> (attribute)) return jsonString (a->value ());
    if (auto a = typed<Imf::StringVectorAttribute> (attribute))
    {
        std::vector<std::string> values;
        for (const std::string& value: a->value ())
            values.push_back (jsonString (value));
        return jsonList (values);
    }
    if (auto a = typed<Imf::TileDescriptionAttribute> (attribute))
    {
        const Imf::TileDescription& t = a->value ();
        return "{\"xSize\": " + std::to_string (t.xSize) + ", \"ySize\": " + std::to_string (t.ySize) +
               ", \"levelMode\": " + jsonString (nameOf (levelModeNames, t.mode)) +
               ", \"roundingMode\": " + jsonString (nameOf (roundingModeNames, t.roundingMode)) + "}";
    }
    if (auto a = typed<Imf::TimeCodeAttribute> (attribute))
        return jsonList ({std::to_string (a->value ().timeAndFlags (Imf::TimeCode::TV60_PACKING)),
                          std::to_string (a->value ().userData ())});
    if (auto a = typed<Imf::V2iAttribute> (attribute))
        return jsonList ({std::to_string (a->value ().x), std::to_string (a->value ().y)});
    if (auto a = typed<Imf::V2fAttribute> (attribute))
        return jsonList ({jsonFloat (a->value ().x), jsonFloat (a->value ().y)});
    if (auto a = typed<Imf::V2dAttribute> (attribute))
        return jsonList ({jsonDouble (a->value ().x), jsonDouble (a->value ().y)});
    if (auto a = typed<Imf::V3iAttribute> (attribute))
        return jsonList ({std::to_string (a->value ().x), std::to_string (a->value ().y), std::to_string (a->value ().z)});
    if (auto a = typed<Imf::V3fAttribute> (attribute))
        return jsonList ({jsonFloat (a->value ().x), jsonFloat (a->value ().y), jsonFloat (a->value ().z)});
    if (auto a = typed<Imf::V3dAttribute> (attribute))
        return jsonList ({jsonDouble (a->value ().x), jsonDouble (a->value ().y), jsonDouble (a->value ().z)});
    return std::string ();
}

template <typename M>
M
matrixFromJson (const Json& json, int size, const std::string& what)
{
    expectArray (json, size_t (size * size), what);
    M matrix;
    for (int i = 0; i < size; i++)
        for (int j = 0; j < size; j++)
            matrix[i][j] = asDouble (json.items[size_t (i * size + j)], what);
    return matrix;
}

// A new attribute of a known type from the JSON of its value.
inline std::unique_ptr<Imf::Attribute>
attributeFromJson (const std::string& type, const Json& value, const std::string& what)
{
    using namespace IMATH_NAMESPACE;
    auto floatAt  = [&] (size_t i) { return asFloat (value.items[i], what + "[" + std::to_string (i) + "]"); };
    auto doubleAt = [&] (size_t i) { return asDouble (value.items[i], what + "[" + std::to_string (i) + "]"); };
    auto intAt    = [&] (size_t i) { return asInt (value.items[i], what + "[" + std::to_string (i) + "]"); };

    if (type == "box2i") return std::make_unique<Imf::Box2iAttribute> (boxFromJson (value, what));
    if (type == "box2f")
    {
        expectArray (value, 4, what);
        return std::make_unique<Imf::Box2fAttribute> (Box2f (V2f (floatAt (0), floatAt (1)), V2f (floatAt (2), floatAt (3))));
    }
    if (type == "chromaticities")
    {
        expectArray (value, 8, what + " ([redX, redY, greenX, greenY, blueX, blueY, whiteX, whiteY])");
        return std::make_unique<Imf::ChromaticitiesAttribute> (Imf::Chromaticities (
            V2f (floatAt (0), floatAt (1)), V2f (floatAt (2), floatAt (3)),
            V2f (floatAt (4), floatAt (5)), V2f (floatAt (6), floatAt (7))));
    }
    if (type == "compression")
        return std::make_unique<Imf::CompressionAttribute> (valueOf (compressionNames, value, what));
    if (type == "double") return std::make_unique<Imf::DoubleAttribute> (asDouble (value, what));
    if (type == "float") return std::make_unique<Imf::FloatAttribute> (asFloat (value, what));
    if (type == "int") return std::make_unique<Imf::IntAttribute> (asInt (value, what));
    if (type == "envmap") return std::make_unique<Imf::EnvmapAttribute> (valueOf (envmapNames, value, what));
    if (type == "deepImageState")
        return std::make_unique<Imf::DeepImageStateAttribute> (valueOf (deepImageStateNames, value, what));
    if (type == "lineOrder") return std::make_unique<Imf::LineOrderAttribute> (valueOf (lineOrderNames, value, what));
    if (type == "floatvector")
    {
        expectKind (value, Json::Array, what);
        Imf::FloatVector values;
        for (size_t i = 0; i < value.items.size (); i++)
            values.push_back (floatAt (i));
        return std::make_unique<Imf::FloatVectorAttribute> (values);
    }
    if (type == "keycode")
    {
        expectArray (value, 7, what + " ([filmMfcCode, filmType, prefix, count, perfOffset, perfsPerFrame, perfsPerCount])");
        return std::make_unique<Imf::KeyCodeAttribute> (
            Imf::KeyCode (intAt (0), intAt (1), intAt (2), intAt (3), intAt (4), intAt (5), intAt (6)));
    }
    if (type == "m33f") return std::make_unique<Imf::M33fAttribute> (matrixFromJson<M33f> (value, 3, what));
    if (type == "m33d") return std::make_unique<Imf::M33dAttribute> (matrixFromJson<M33d> (value, 3, what));
    if (type == "m44f") return std::make_unique<Imf::M44fAttribute> (matrixFromJson<M44f> (value, 4, what));
    if (type == "m44d") return std::make_unique<Imf::M44dAttribute> (matrixFromJson<M44d> (value, 4, what));
    if (type == "preview")
    {
        expectKind (value, Json::Object, what);
        const Json* width  = value.find ("width");
        const Json* height = value.find ("height");
        const Json* pixels = value.find ("pixels");
        if (!width || !height || !pixels) fail (what + " must have width, height and pixels");
        unsigned          w     = asUnsigned (*width, what + ".width");
        unsigned          h     = asUnsigned (*height, what + ".height");
        std::vector<char> bytes = unhex (asString (*pixels, what + ".pixels"), what + ".pixels");
        if (bytes.size () != size_t (w) * h * 4)
            fail (what + ".pixels must have width * height * 4 bytes (RGBA)");
        std::vector<Imf::PreviewRgba> rgba (size_t (w) * h);
        for (size_t i = 0; i < rgba.size (); i++)
            rgba[i] = Imf::PreviewRgba (
                (unsigned char) bytes[4 * i], (unsigned char) bytes[4 * i + 1],
                (unsigned char) bytes[4 * i + 2], (unsigned char) bytes[4 * i + 3]);
        return std::make_unique<Imf::PreviewImageAttribute> (Imf::PreviewImage (w, h, rgba.data ()));
    }
    if (type == "rational")
    {
        expectArray (value, 2, what + " ([numerator, denominator])");
        return std::make_unique<Imf::RationalAttribute> (
            Imf::Rational (intAt (0), asUnsigned (value.items[1], what + "[1]")));
    }
    if (type == "string") return std::make_unique<Imf::StringAttribute> (asString (value, what));
    if (type == "stringvector")
    {
        expectKind (value, Json::Array, what);
        Imf::StringVector values;
        for (size_t i = 0; i < value.items.size (); i++)
            values.push_back (asString (value.items[i], what + "[" + std::to_string (i) + "]"));
        return std::make_unique<Imf::StringVectorAttribute> (values);
    }
    if (type == "tiledesc")
    {
        expectKind (value, Json::Object, what);
        const Json* xSize = value.find ("xSize");
        const Json* ySize = value.find ("ySize");
        if (!xSize || !ySize) fail (what + " must have xSize and ySize");
        Imf::TileDescription tiles (asUnsigned (*xSize, what + ".xSize"), asUnsigned (*ySize, what + ".ySize"));
        if (const Json* mode = value.find ("levelMode")) tiles.mode = valueOf (levelModeNames, *mode, what + ".levelMode");
        if (const Json* rounding = value.find ("roundingMode"))
            tiles.roundingMode = valueOf (roundingModeNames, *rounding, what + ".roundingMode");
        return std::make_unique<Imf::TileDescriptionAttribute> (tiles);
    }
    if (type == "timecode")
    {
        expectArray (value, 2, what + " ([timeAndFlags, userData])");
        return std::make_unique<Imf::TimeCodeAttribute> (Imf::TimeCode (
            asUnsigned (value.items[0], what + "[0]"), asUnsigned (value.items[1], what + "[1]"),
            Imf::TimeCode::TV60_PACKING));
    }
    if (type == "v2i")
    {
        expectArray (value, 2, what);
        return std::make_unique<Imf::V2iAttribute> (V2i (intAt (0), intAt (1)));
    }
    if (type == "v2f")
    {
        expectArray (value, 2, what);
        return std::make_unique<Imf::V2fAttribute> (V2f (floatAt (0), floatAt (1)));
    }
    if (type == "v2d")
    {
        expectArray (value, 2, what);
        return std::make_unique<Imf::V2dAttribute> (V2d (doubleAt (0), doubleAt (1)));
    }
    if (type == "v3i")
    {
        expectArray (value, 3, what);
        return std::make_unique<Imf::V3iAttribute> (V3i (intAt (0), intAt (1), intAt (2)));
    }
    if (type == "v3f")
    {
        expectArray (value, 3, what);
        return std::make_unique<Imf::V3fAttribute> (V3f (floatAt (0), floatAt (1), floatAt (2)));
    }
    if (type == "v3d")
    {
        expectArray (value, 3, what);
        return std::make_unique<Imf::V3dAttribute> (V3d (doubleAt (0), doubleAt (1), doubleAt (2)));
    }
    fail (what + ": the type \"" + type + "\" has no JSON value; give its bytes in \"data\" instead");
}

} // namespace exrraw

#endif
