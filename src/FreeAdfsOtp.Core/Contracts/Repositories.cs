using FreeAdfsOtp.Core.Models;

namespace FreeAdfsOtp.Core.Contracts;

public interface IOtpRepository
{
    Task<OtpUser?> GetUserByUpnAsync(string userPrincipalName, CancellationToken cancellationToken);
    Task<OtpMethod?> GetPrimaryMethodAsync(Guid userId, CancellationToken cancellationToken);
    Task<UserLockoutState> GetOrCreateLockoutAsync(Guid userId, CancellationToken cancellationToken);
    Task SaveLockoutAsync(UserLockoutState state, CancellationToken cancellationToken);
    Task UpdateLastAcceptedTimeStepAsync(Guid methodId, long timeStep, CancellationToken cancellationToken);
    Task SaveEnrollmentAsync(string userPrincipalName, byte[] encryptedSecret, int keyVersion, CancellationToken cancellationToken);
    Task SavePendingEnrollmentAsync(PendingEnrollmentState pendingEnrollment, CancellationToken cancellationToken);
    Task<PendingEnrollmentState?> GetPendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken);
    Task DeletePendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken);
    Task<int> DeleteExpiredPendingEnrollmentsAsync(DateTimeOffset utcNow, CancellationToken cancellationToken);
    Task LogOtpAttemptAsync(
        OtpUser? user,
        string userPrincipalName,
        string? methodType,
        bool isSuccess,
        OtpFailureReason failureReason,
        string? clientIp,
        string? userAgent,
        Guid? correlationId,
        Guid? adfsActivityId,
        CancellationToken cancellationToken);

    Task ResetUserMethodsAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken);
    Task UnlockUserAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken);
}

public interface ISecretProtector
{
    byte[] Protect(byte[] rawSecret, int keyVersion);
    byte[] Unprotect(byte[] protectedSecret, int keyVersion);
}
