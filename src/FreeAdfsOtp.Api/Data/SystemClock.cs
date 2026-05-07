using FreeAdfsOtp.Api.Contracts;

namespace FreeAdfsOtp.Api.Data;

public sealed class SystemClock : IClock
{
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}
