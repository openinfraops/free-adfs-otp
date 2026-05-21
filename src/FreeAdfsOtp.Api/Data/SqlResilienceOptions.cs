namespace FreeAdfsOtp.Api.Data;

public sealed class SqlResilienceOptions
{
    public const string SectionName = "SqlResilience";

    public int DegradedModeWindowSeconds { get; set; } = 30;
    public int ProbeIntervalSeconds { get; set; } = 5;
}
