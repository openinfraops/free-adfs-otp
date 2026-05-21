using Microsoft.Extensions.Options;

namespace FreeAdfsOtp.Api.Data;

public sealed class SqlAvailabilityState
{
    private readonly SqlResilienceOptions _options;
    private readonly object _gate = new();
    private DateTimeOffset? _degradedUntilUtc;

    public SqlAvailabilityState(IOptions<SqlResilienceOptions> options)
    {
        _options = options.Value;
    }

    public bool ShouldBypassSql(DateTimeOffset now)
    {
        lock (_gate)
        {
            return _degradedUntilUtc.HasValue && now < _degradedUntilUtc.Value;
        }
    }

    public void MarkUnavailable(DateTimeOffset now)
    {
        var windowSeconds = _options.DegradedModeWindowSeconds <= 0 ? 30 : _options.DegradedModeWindowSeconds;
        var newDegradedUntil = now.AddSeconds(windowSeconds);

        lock (_gate)
        {
            if (!_degradedUntilUtc.HasValue || _degradedUntilUtc.Value < newDegradedUntil)
            {
                _degradedUntilUtc = newDegradedUntil;
            }
        }
    }

    public void MarkAvailable()
    {
        lock (_gate)
        {
            _degradedUntilUtc = null;
        }
    }
}
