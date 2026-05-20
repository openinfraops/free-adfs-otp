using FreeAdfsOtp.Api.Data;
using Microsoft.Extensions.Options;

namespace FreeAdfsOtp.Api.Background;

public sealed class LocalCachePeriodicSyncService : BackgroundService
{
    private readonly LocalCacheOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<LocalCachePeriodicSyncService> _logger;

    public LocalCachePeriodicSyncService(
        IOptions<LocalCacheOptions> options,
        IServiceScopeFactory scopeFactory,
        ILogger<LocalCachePeriodicSyncService> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled || !_options.PeriodicSyncEnabled)
        {
            _logger.LogInformation("Local cache periodic sync disabled (Enabled={Enabled}, PeriodicSyncEnabled={PeriodicSyncEnabled}).", _options.Enabled, _options.PeriodicSyncEnabled);
            return;
        }

        var intervalSeconds = _options.PeriodicSyncIntervalSeconds <= 0 ? 30 : _options.PeriodicSyncIntervalSeconds;
        var interval = TimeSpan.FromSeconds(intervalSeconds);

        _logger.LogInformation("Local cache periodic sync started with interval {IntervalSeconds}s.", intervalSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await SyncOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Local cache periodic sync failed. Will retry next interval.");
            }

            try
            {
                await Task.Delay(interval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }

        _logger.LogInformation("Local cache periodic sync stopped.");
    }

    private async Task SyncOnceAsync(CancellationToken cancellationToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var sqlRepository = scope.ServiceProvider.GetRequiredService<SqlOtpRepository>();
        var localCache = scope.ServiceProvider.GetRequiredService<LocalOtpCacheStore>();

        var cachedUpns = await localCache.GetCachedUserPrincipalNamesAsync(cancellationToken);
        foreach (var upn in cachedUpns)
        {
            var user = await sqlRepository.GetUserByUpnAsync(upn, cancellationToken);
            if (user is null)
            {
                await localCache.DeleteUserByUpnAsync(upn, cancellationToken);
                continue;
            }

            await localCache.UpsertUserAsync(user, cancellationToken);

            var method = await sqlRepository.GetPrimaryMethodAsync(user.UserId, cancellationToken);
            if (method is not null)
            {
                await localCache.UpsertMethodAsync(method, cancellationToken);
            }

            var lockout = await sqlRepository.GetOrCreateLockoutAsync(user.UserId, cancellationToken);
            await localCache.SaveLockoutAsync(lockout, cancellationToken);
        }
    }
}
