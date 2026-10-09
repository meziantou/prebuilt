namespace Meziantou.Prebuilt.Tests;

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        FullPath = Path.Combine(Path.GetTempPath(), "Meziantou.Prebuilt.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(FullPath);
    }

    public string FullPath { get; }

    public string[] GetFiles() => Directory.GetFiles(FullPath, "*", SearchOption.AllDirectories);

    public void Dispose()
    {
        try
        {
            Directory.Delete(FullPath, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
