namespace FreeAdfsOtp.Api.Data;

public sealed class LocalCacheOptions
{
    public const string SectionName = "LocalCache";

    public bool Enabled { get; set; } = false;
    public bool AllowSqlFallbackForValidation { get; set; } = true;
    public string DatabasePath { get; set; } = "cache/freeadfsotp-node-cache.db";
    public bool InitialFullSyncEnabled { get; set; } = true;
    public bool PeriodicSyncEnabled { get; set; } = true;
    public int PeriodicSyncIntervalSeconds { get; set; } = 30;
}
