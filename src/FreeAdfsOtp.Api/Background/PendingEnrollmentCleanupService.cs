using FreeAdfsOtp.Api.Contracts;
using FreeAdfsOtp.Api.Security;
using FreeAdfsOtp.Core.Contracts;

namespace FreeAdfsOtp.Api.Background;

public sealed class PendingEnrollmentCleanupService : BackgroundService
{
    private readonly IServiceProvider _serviceProvider;
    private readonly IConfiguration _configuration;
    private readonly RequestThrottleService _throttle;

    public PendingEnrollmentCleanupService(
        IServiceProvider serviceProvider,
        IConfiguration configuration,
        RequestThrottleService throttle)
    {
        _serviceProvider = serviceProvider;
        _configuration = configuration;
        _throttle = throttle;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var cleanupIntervalMinutes = _configuration.GetValue<int?>("Enrollment:CleanupIntervalMinutes") ?? 5;
        var interval = TimeSpan.FromMinutes(Math.Max(1, cleanupIntervalMinutes));

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _serviceProvider.CreateScope();
                var repository = scope.ServiceProvider.GetRequiredService<IOtpRepository>();
                var clock = scope.ServiceProvider.GetRequiredService<IClock>();

                await repository.DeleteExpiredPendingEnrollmentsAsync(clock.UtcNow, stoppingToken);
                _throttle.CleanupOlderThan(clock.UtcNow.AddMinutes(-30));
            }
            catch
            {
                // Keep background cleanup resilient to transient DB/network issues.
            }

            await Task.Delay(interval, stoppingToken);
        }
    }
}
