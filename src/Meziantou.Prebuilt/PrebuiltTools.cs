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

    /// <summary>ffmpeg, from the BtbN/FFmpeg-Builds GPL build.</summary>
    public static PrebuiltTool Ffmpeg { get; } = new("ffmpeg");

    /// <summary>ffprobe, from the BtbN/FFmpeg-Builds GPL build.</summary>
    public static PrebuiltTool Ffprobe { get; } = new("ffprobe");

    /// <summary>ffmpeg, from the custom statically linked build.</summary>
    public static PrebuiltTool FfmpegCustom { get; } = new("ffmpeg-custom");

    /// <summary>ffprobe, from the custom statically linked build.</summary>
    public static PrebuiltTool FfprobeCustom { get; } = new("ffprobe-custom");

    /// <summary>cwebp, the libwebp encoder.</summary>
    public static PrebuiltTool Cwebp { get; } = new("cwebp");

    /// <summary>dwebp, the libwebp decoder.</summary>
    public static PrebuiltTool Dwebp { get; } = new("dwebp");

    /// <summary>webpmux, the libwebp muxing tool.</summary>
    public static PrebuiltTool Webpmux { get; } = new("webpmux");

    /// <summary>anim_dump, the libwebp tool that dumps the frames of an animated image.</summary>
    public static PrebuiltTool WebpAnimDump { get; } = new("anim_dump");

    /// <summary>Gets all the tools.</summary>
    public static IReadOnlyList<PrebuiltTool> All { get; } =
    [
        Zopfli,
        Oxipng,
        Pngout,
        Ffmpeg,
        Ffprobe,
        FfmpegCustom,
        FfprobeCustom,
        Cwebp,
        Dwebp,
        Webpmux,
        WebpAnimDump,
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
