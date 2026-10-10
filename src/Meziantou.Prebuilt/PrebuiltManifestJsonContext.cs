using System.Text.Json.Serialization;

namespace Meziantou.Prebuilt;

#if NET9_0_OR_GREATER
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, RespectNullableAnnotations = true, RespectRequiredConstructorParameters = true)]
#else
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
#endif
[JsonSerializable(typeof(PrebuiltManifestModel))]
internal sealed partial class PrebuiltManifestJsonContext : JsonSerializerContext;
