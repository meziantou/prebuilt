using System.Collections.Concurrent;
using System.Net;

namespace Meziantou.Prebuilt.Tests;

internal sealed class FakeHttpMessageHandler : HttpMessageHandler
{
    private readonly ConcurrentDictionary<Uri, byte[]> _responses = new();
    private readonly TaskCompletionSource _requestReceived = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _requestCount;

    public int RequestCount => _requestCount;

    /// <summary>Completes once the first request has reached the handler.</summary>
    public Task RequestReceived => _requestReceived.Task;

    public TimeSpan Delay { get; set; }

    /// <summary>When set, responses are sent only once this task completes.</summary>
    public Task? ResponseGate { get; set; }

    public void Add(Uri url, byte[] content) => _responses[url] = content;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _requestCount);
        _requestReceived.TrySetResult();
        if (Delay > TimeSpan.Zero)
        {
            await Task.Delay(Delay, cancellationToken);
        }

        if (ResponseGate is not null)
        {
            await ResponseGate.WaitAsync(cancellationToken);
        }

        if (request.RequestUri is not null && _responses.TryGetValue(request.RequestUri, out var content))
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(content) };

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    }
}
