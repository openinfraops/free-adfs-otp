using FreeAdfsOtp.Core.Contracts;
using FreeAdfsOtp.Core.Models;

namespace FreeAdfsOtp.Core.Services;

public sealed class OtpValidationService
{
    private readonly IOtpRepository _repository;
    private readonly ISecretProtector _secretProtector;

    public OtpValidationService(IOtpRepository repository, ISecretProtector secretProtector)
    {
        _repository = repository;
        _secretProtector = secretProtector;
    }

    public async Task<OtpValidationResult> ValidateAsync(
        OtpValidationRequest request,
        OtpSettings settings,
        DateTimeOffset utcNow,
        CancellationToken cancellationToken)
    {
        var user = await _repository.GetUserByUpnAsync(request.UserPrincipalName, cancellationToken);
        if (user is null)
        {
            await _repository.LogOtpAttemptAsync(
                null,
                request.UserPrincipalName,
                null,
                false,
                OtpFailureReason.NotEnrolled,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.NotEnrolled, null, true);
        }

        if (!user.IsActive || !user.IsEnrolled)
        {
            await _repository.LogOtpAttemptAsync(
                user,
                user.UserPrincipalName,
                null,
                false,
                OtpFailureReason.NotEnrolled,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.NotEnrolled, null, true);
        }

        var method = await _repository.GetPrimaryMethodAsync(user.UserId, cancellationToken);
        if (method is null || !method.IsEnabled)
        {
            await _repository.LogOtpAttemptAsync(
                user,
                user.UserPrincipalName,
                method?.MethodType,
                false,
                OtpFailureReason.NotEnrolled,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.NotEnrolled, null, true);
        }

        var lockout = await _repository.GetOrCreateLockoutAsync(user.UserId, cancellationToken);
        if (LockoutPolicy.IsLocked(lockout, utcNow))
        {
            await _repository.LogOtpAttemptAsync(
                user,
                user.UserPrincipalName,
                method.MethodType,
                false,
                OtpFailureReason.Locked,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.Locked, lockout.LockedUntilUtc, false);
        }

        var rawSecret = _secretProtector.Unprotect(method.SecretCiphertext, method.SecretKeyVersion);
        if (!TotpService.ValidateCode(request.Code, rawSecret, settings, utcNow, out var matchedTimeStep))
        {
            var failedState = LockoutPolicy.RegisterFailure(lockout, settings, utcNow);
            await _repository.SaveLockoutAsync(failedState, cancellationToken);

            await _repository.LogOtpAttemptAsync(
                user,
                user.UserPrincipalName,
                method.MethodType,
                false,
                OtpFailureReason.InvalidCode,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.InvalidCode, failedState.LockedUntilUtc, false);
        }

        if (method.LastAcceptedTimeStep.HasValue && matchedTimeStep <= method.LastAcceptedTimeStep.Value)
        {
            await _repository.LogOtpAttemptAsync(
                user,
                user.UserPrincipalName,
                method.MethodType,
                false,
                OtpFailureReason.Replay,
                request.ClientIp,
                request.UserAgent,
                request.CorrelationId,
                request.AdfsActivityId,
                cancellationToken);

            return new OtpValidationResult(false, OtpFailureReason.Replay, null, false);
        }

        await _repository.UpdateLastAcceptedTimeStepAsync(method.MethodId, matchedTimeStep, cancellationToken);
        var successState = LockoutPolicy.RegisterSuccess(lockout);
        await _repository.SaveLockoutAsync(successState, cancellationToken);

        await _repository.LogOtpAttemptAsync(
            user,
            user.UserPrincipalName,
            method.MethodType,
            true,
            OtpFailureReason.None,
            request.ClientIp,
            request.UserAgent,
            request.CorrelationId,
            request.AdfsActivityId,
            cancellationToken);

        return new OtpValidationResult(true, OtpFailureReason.None, null, false);
    }
}
