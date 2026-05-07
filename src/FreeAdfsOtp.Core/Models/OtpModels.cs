namespace FreeAdfsOtp.Core.Models;

public enum OtpFailureReason
{
    None = 0,
    InvalidCode = 1,
    Locked = 2,
    NotEnrolled = 3,
    Replay = 4,
    Disabled = 5
}

public sealed record OtpSettings(
    int Digits,
    int StepSeconds,
    int AllowedSkewSteps,
    int MaxFailedAttempts,
    int FailedWindowMinutes,
    int LockoutMinutes);

public sealed record OtpValidationRequest(
    string UserPrincipalName,
    string Code,
    string? ClientIp,
    string? UserAgent,
    Guid? CorrelationId,
    Guid? AdfsActivityId);

public sealed record OtpValidationResult(
    bool IsSuccess,
    OtpFailureReason FailureReason,
    DateTimeOffset? LockedUntilUtc,
    bool RequiresEnrollment);

public sealed record OtpUser(
    Guid UserId,
    string UserPrincipalName,
    bool IsEnrolled,
    bool IsActive);

public sealed record OtpMethod(
    Guid MethodId,
    Guid UserId,
    string MethodType,
    bool IsEnabled,
    int SecretKeyVersion,
    byte[] SecretCiphertext,
    long? LastAcceptedTimeStep);

public sealed record UserLockoutState(
    Guid UserId,
    int FailedAttemptsInWindow,
    DateTimeOffset? WindowStartUtc,
    DateTimeOffset? LockedUntilUtc,
    DateTimeOffset? LastFailureUtc);

public sealed record PendingEnrollmentState(
    string UserPrincipalName,
    string SecretBase32,
    string IdpName,
    string AccountName,
    DateTimeOffset ExpiresUtc);
