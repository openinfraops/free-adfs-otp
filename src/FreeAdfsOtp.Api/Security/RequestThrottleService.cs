using System.Collections.Concurrent;

namespace FreeAdfsOtp.Api.Security;

public sealed class RequestThrottleService
{
    private readonly ConcurrentDictionary<string, CounterWindow> _windows = new(StringComparer.OrdinalIgnoreCase);

    public bool TryAcquire(string scope, string key, int limit, TimeSpan window, DateTimeOffset utcNow, out int retryAfterSeconds)
    {
        retryAfterSeconds = 0;
        var bucketKey = scope + ":" + key;

        var state = _windows.AddOrUpdate(
            bucketKey,
            _ => new CounterWindow(utcNow, 1),
            (_, current) => UpdateWindow(current, utcNow, window));

        if (state.Count > limit)
        {
            var untilReset = state.WindowStartUtc.Add(window) - utcNow;
            retryAfterSeconds = Math.Max(1, (int)Math.Ceiling(untilReset.TotalSeconds));
            return false;
        }

        return true;
    }

    private static CounterWindow UpdateWindow(CounterWindow current, DateTimeOffset utcNow, TimeSpan window)
    {
        if (current.WindowStartUtc.Add(window) <= utcNow)
        {
            return new CounterWindow(utcNow, 1);
        }

        return current with { Count = current.Count + 1 };
    }

    public void CleanupOlderThan(DateTimeOffset thresholdUtc)
    {
        foreach (var item in _windows)
        {
            if (item.Value.WindowStartUtc < thresholdUtc)
            {
                _windows.TryRemove(item.Key, out _);
            }
        }
    }

    private sealed record CounterWindow(DateTimeOffset WindowStartUtc, int Count);
}
