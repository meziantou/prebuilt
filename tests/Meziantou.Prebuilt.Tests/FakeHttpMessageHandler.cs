using System.Collections.Concurrent;
using System.Net;

namespace Meziantou.Prebuilt.Tests;

internal sealed class FakeHttpMessageHandler : HttpMessageHandler
{
    private readonly ConcurrentDictionary<Uri, byte[]> _responses = new();
    private int _requestCount;

    public int RequestCount => _requestCount;

    public TimeSpan Delay { get; set; }

    public void Add(Uri url, byte[] content) => _responses[url] = content;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _requestCount);
        if (Delay > TimeSpan.Zero)
        {
            await Task.Delay(Delay, cancellationToken);
        }

        if (request.RequestUri is not null && _responses.TryGetValue(request.RequestUri, out var content))
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(content) };

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    }
}
