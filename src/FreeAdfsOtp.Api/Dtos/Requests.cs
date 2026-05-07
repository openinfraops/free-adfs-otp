namespace FreeAdfsOtp.Api.Dtos;

public sealed record ValidateOtpDto(
    string UserPrincipalName,
    string Code,
    string? ClientIp,
    string? UserAgent,
    Guid? CorrelationId,
    Guid? AdfsActivityId);

public sealed record EnrollmentStartDto(string UserPrincipalName, string IdpName, string? AccountName);
public sealed record EnrollmentVerifyDto(string UserPrincipalName, string Code);
public sealed record AdminActionDto(string AdminUpn, string Reason);
