using System.Text.Json.Serialization;

namespace Meziantou.Prebuilt;

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(PrebuiltManifestModel))]
internal sealed partial class PrebuiltManifestJsonContext : JsonSerializerContext;
