using FreeAdfsOtp.Core.Contracts;
using FreeAdfsOtp.Core.Models;
using Microsoft.Extensions.Options;

namespace FreeAdfsOtp.Api.Data;

public sealed class CachedOtpRepository : IOtpRepository
{
    private readonly SqlOtpRepository _sqlRepository;
    private readonly LocalOtpCacheStore _localCache;
    private readonly LocalCacheOptions _options;
    private readonly ILogger<CachedOtpRepository> _logger;

    public CachedOtpRepository(
        SqlOtpRepository sqlRepository,
        LocalOtpCacheStore localCache,
        IOptions<LocalCacheOptions> options,
        ILogger<CachedOtpRepository> logger)
    {
        _sqlRepository = sqlRepository;
        _localCache = localCache;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<OtpUser?> GetUserByUpnAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        try
        {
            var user = await _sqlRepository.GetUserByUpnAsync(userPrincipalName, cancellationToken);
            if (user is null)
            {
                await _localCache.DeleteUserByUpnAsync(userPrincipalName, cancellationToken);
                return null;
            }

            await _localCache.UpsertUserAsync(user, cancellationToken);
            return user;
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while reading user {UserPrincipalName}, falling back to local cache.", userPrincipalName);
            return await _localCache.GetUserByUpnAsync(userPrincipalName, cancellationToken);
        }
    }

    public async Task<OtpMethod?> GetPrimaryMethodAsync(Guid userId, CancellationToken cancellationToken)
    {
        try
        {
            var method = await _sqlRepository.GetPrimaryMethodAsync(userId, cancellationToken);
            if (method is not null)
            {
                await _localCache.UpsertMethodAsync(method, cancellationToken);
            }

            return method;
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while reading method for userId {UserId}, falling back to local cache.", userId);
            return await _localCache.GetPrimaryMethodAsync(userId, cancellationToken);
        }
    }

    public async Task<UserLockoutState> GetOrCreateLockoutAsync(Guid userId, CancellationToken cancellationToken)
    {
        try
        {
            var lockout = await _sqlRepository.GetOrCreateLockoutAsync(userId, cancellationToken);
            await _localCache.SaveLockoutAsync(lockout, cancellationToken);
            return lockout;
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while reading lockout for userId {UserId}, falling back to local cache.", userId);
            return await _localCache.GetOrCreateLockoutAsync(userId, cancellationToken);
        }
    }

    public async Task SaveLockoutAsync(UserLockoutState state, CancellationToken cancellationToken)
    {
        await _localCache.SaveLockoutAsync(state, cancellationToken);

        try
        {
            await _sqlRepository.SaveLockoutAsync(state, cancellationToken);
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while saving lockout for userId {UserId}. Local cache retained state.", state.UserId);
        }
    }

    public async Task UpdateLastAcceptedTimeStepAsync(Guid methodId, long timeStep, CancellationToken cancellationToken)
    {
        await _localCache.UpdateLastAcceptedTimeStepAsync(methodId, timeStep, cancellationToken);

        try
        {
            await _sqlRepository.UpdateLastAcceptedTimeStepAsync(methodId, timeStep, cancellationToken);
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while saving replay step for methodId {MethodId}. Local cache retained state.", methodId);
        }
    }

    public async Task SaveEnrollmentAsync(string userPrincipalName, byte[] encryptedSecret, int keyVersion, CancellationToken cancellationToken)
    {
        await _sqlRepository.SaveEnrollmentAsync(userPrincipalName, encryptedSecret, keyVersion, cancellationToken);
        await RefreshUserCacheAsync(userPrincipalName, cancellationToken);
    }

    public async Task SavePendingEnrollmentAsync(PendingEnrollmentState pendingEnrollment, CancellationToken cancellationToken)
    {
        await _sqlRepository.SavePendingEnrollmentAsync(pendingEnrollment, cancellationToken);
        await _localCache.UpsertPendingEnrollmentAsync(pendingEnrollment, cancellationToken);
    }

    public async Task<PendingEnrollmentState?> GetPendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        try
        {
            var pending = await _sqlRepository.GetPendingEnrollmentAsync(userPrincipalName, cancellationToken);
            if (pending is not null)
            {
                await _localCache.UpsertPendingEnrollmentAsync(pending, cancellationToken);
            }

            return pending;
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while reading pending enrollment for {UserPrincipalName}, falling back to local cache.", userPrincipalName);
            return await _localCache.GetPendingEnrollmentAsync(userPrincipalName, cancellationToken);
        }
    }

    public async Task DeletePendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        await _sqlRepository.DeletePendingEnrollmentAsync(userPrincipalName, cancellationToken);
        await _localCache.DeletePendingEnrollmentAsync(userPrincipalName, cancellationToken);
    }

    public async Task<int> DeleteExpiredPendingEnrollmentsAsync(DateTimeOffset utcNow, CancellationToken cancellationToken)
    {
        var sqlDeleted = await _sqlRepository.DeleteExpiredPendingEnrollmentsAsync(utcNow, cancellationToken);
        await _localCache.DeleteExpiredPendingEnrollmentsAsync(utcNow, cancellationToken);
        return sqlDeleted;
    }

    public async Task LogOtpAttemptAsync(
        OtpUser? user,
        string userPrincipalName,
        string? methodType,
        bool isSuccess,
        OtpFailureReason failureReason,
        string? clientIp,
        string? userAgent,
        Guid? correlationId,
        Guid? adfsActivityId,
        CancellationToken cancellationToken)
    {
        try
        {
            await _sqlRepository.LogOtpAttemptAsync(
                user,
                userPrincipalName,
                methodType,
                isSuccess,
                failureReason,
                clientIp,
                userAgent,
                correlationId,
                adfsActivityId,
                cancellationToken);
        }
        catch (Exception ex) when (_options.AllowSqlFallbackForValidation)
        {
            _logger.LogWarning(ex, "SQL unavailable while logging OTP attempt for {UserPrincipalName}. Writing in local cache only.", userPrincipalName);
        }

        await _localCache.LogOtpAttemptAsync(
            user,
            userPrincipalName,
            methodType,
            isSuccess,
            failureReason,
            clientIp,
            userAgent,
            correlationId,
            adfsActivityId,
            cancellationToken);
    }

    public async Task ResetUserMethodsAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken)
    {
        await _sqlRepository.ResetUserMethodsAsync(targetUserUpn, adminUpn, reason, cancellationToken);
        await _localCache.MarkUserMethodsResetAsync(targetUserUpn, cancellationToken);
    }

    public async Task UnlockUserAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken)
    {
        await _sqlRepository.UnlockUserAsync(targetUserUpn, adminUpn, reason, cancellationToken);
        await _localCache.UnlockUserAsync(targetUserUpn, cancellationToken);
    }

    private async Task RefreshUserCacheAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        var user = await _sqlRepository.GetUserByUpnAsync(userPrincipalName, cancellationToken);
        if (user is null)
        {
            await _localCache.DeleteUserByUpnAsync(userPrincipalName, cancellationToken);
            return;
        }

        await _localCache.UpsertUserAsync(user, cancellationToken);

        var method = await _sqlRepository.GetPrimaryMethodAsync(user.UserId, cancellationToken);
        if (method is not null)
        {
            await _localCache.UpsertMethodAsync(method, cancellationToken);
        }

        var lockout = await _sqlRepository.GetOrCreateLockoutAsync(user.UserId, cancellationToken);
        await _localCache.SaveLockoutAsync(lockout, cancellationToken);
    }
}
