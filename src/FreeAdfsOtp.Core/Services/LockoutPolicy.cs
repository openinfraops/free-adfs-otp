using FreeAdfsOtp.Core.Models;

namespace FreeAdfsOtp.Core.Services;

public static class LockoutPolicy
{
    public static bool IsLocked(UserLockoutState state, DateTimeOffset utcNow)
    {
        return state.LockedUntilUtc.HasValue && state.LockedUntilUtc.Value > utcNow;
    }

    public static UserLockoutState RegisterFailure(UserLockoutState state, OtpSettings settings, DateTimeOffset utcNow)
    {
        var windowStart = state.WindowStartUtc;
        var attempts = state.FailedAttemptsInWindow;

        if (!windowStart.HasValue || windowStart.Value.AddMinutes(settings.FailedWindowMinutes) < utcNow)
        {
            windowStart = utcNow;
            attempts = 0;
        }

        attempts += 1;

        DateTimeOffset? lockedUntil = state.LockedUntilUtc;
        if (attempts >= settings.MaxFailedAttempts)
        {
            lockedUntil = utcNow.AddMinutes(settings.LockoutMinutes);
            attempts = 0;
            windowStart = utcNow;
        }

        return state with
        {
            FailedAttemptsInWindow = attempts,
            WindowStartUtc = windowStart,
            LockedUntilUtc = lockedUntil,
            LastFailureUtc = utcNow
        };
    }

    public static UserLockoutState RegisterSuccess(UserLockoutState state)
    {
        return state with
        {
            FailedAttemptsInWindow = 0,
            WindowStartUtc = null,
            LockedUntilUtc = null,
            LastFailureUtc = null
        };
    }
}
