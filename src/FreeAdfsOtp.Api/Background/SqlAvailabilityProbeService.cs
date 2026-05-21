using FreeAdfsOtp.Api.Contracts;
using FreeAdfsOtp.Api.Data;
using Microsoft.Extensions.Options;

namespace FreeAdfsOtp.Api.Background;

public sealed class SqlAvailabilityProbeService : BackgroundService
{
    private readonly LocalCacheOptions _cacheOptions;
    private readonly SqlResilienceOptions _resilienceOptions;
    private readonly SqlAvailabilityState _availabilityState;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IClock _clock;
    private readonly ILogger<SqlAvailabilityProbeService> _logger;

    public SqlAvailabilityProbeService(
        IOptions<LocalCacheOptions> cacheOptions,
        IOptions<SqlResilienceOptions> resilienceOptions,
        SqlAvailabilityState availabilityState,
        IServiceScopeFactory scopeFactory,
        IClock clock,
        ILogger<SqlAvailabilityProbeService> logger)
    {
        _cacheOptions = cacheOptions.Value;
        _resilienceOptions = resilienceOptions.Value;
        _availabilityState = availabilityState;
        _scopeFactory = scopeFactory;
        _clock = clock;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_cacheOptions.Enabled || !_cacheOptions.AllowSqlFallbackForValidation)
        {
            return;
        }

        var probeIntervalSeconds = _resilienceOptions.ProbeIntervalSeconds <= 0 ? 5 : _resilienceOptions.ProbeIntervalSeconds;
        var probeInterval = TimeSpan.FromSeconds(probeIntervalSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (_availabilityState.ShouldBypassSql(_clock.UtcNow))
                {
                    using var scope = _scopeFactory.CreateScope();
                    var sqlRepository = scope.ServiceProvider.GetRequiredService<SqlOtpRepository>();
                    await sqlRepository.ProbeConnectivityAsync(stoppingToken);
                    _availabilityState.MarkAvailable();
                    _logger.LogInformation("SQL connectivity restored; leaving degraded cache-first mode.");
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "SQL probe still failing during degraded mode.");
            }

            try
            {
                await Task.Delay(probeInterval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }
}
