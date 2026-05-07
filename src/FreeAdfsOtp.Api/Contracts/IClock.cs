namespace FreeAdfsOtp.Api.Contracts;

public interface IClock
{
    DateTimeOffset UtcNow { get; }
}
