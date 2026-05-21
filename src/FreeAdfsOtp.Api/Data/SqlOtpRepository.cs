using System.Data;
using FreeAdfsOtp.Core.Contracts;
using FreeAdfsOtp.Core.Models;
using Microsoft.Data.SqlClient;

namespace FreeAdfsOtp.Api.Data;

public sealed class SqlOtpRepository : IOtpRepository
{
    private readonly string _connectionString;

    public SqlOtpRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("OtpSql")
            ?? throw new InvalidOperationException("Missing ConnectionStrings:OtpSql.");
    }

    public async Task<OtpUser?> GetUserByUpnAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand("otp.GetUserByUpn", connection)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@UserPrincipalName", userPrincipalName);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new OtpUser(
            reader.GetGuid(reader.GetOrdinal("UserId")),
            reader.GetString(reader.GetOrdinal("UserPrincipalName")),
            reader.GetBoolean(reader.GetOrdinal("IsEnrolled")),
            reader.GetBoolean(reader.GetOrdinal("IsActive")));
    }

    public async Task<IReadOnlyList<OtpUser>> GetAllUsersAsync(CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT UserId, UserPrincipalName, IsEnrolled, IsActive
FROM otp.Users;";

        var users = new List<OtpUser>();

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            users.Add(new OtpUser(
                reader.GetGuid(reader.GetOrdinal("UserId")),
                reader.GetString(reader.GetOrdinal("UserPrincipalName")),
                reader.GetBoolean(reader.GetOrdinal("IsEnrolled")),
                reader.GetBoolean(reader.GetOrdinal("IsActive"))));
        }

        return users;
    }

    public async Task ProbeConnectivityAsync(CancellationToken cancellationToken)
    {
        const string sql = "SELECT 1;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        await cmd.ExecuteScalarAsync(cancellationToken);
    }

    public async Task<OtpMethod?> GetPrimaryMethodAsync(Guid userId, CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT TOP 1
    m.MethodId,
    m.UserId,
    m.MethodType,
    m.IsEnabled,
    s.SecretKeyVersion,
    s.SecretCiphertext,
    s.LastAcceptedTimeStep
FROM otp.OtpMethods m
INNER JOIN otp.OtpSecrets s ON s.MethodId = m.MethodId
WHERE m.UserId = @UserId
  AND m.IsPrimaryMethod = 1
ORDER BY m.EnrolledUtc DESC;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserId", userId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new OtpMethod(
            reader.GetGuid(reader.GetOrdinal("MethodId")),
            reader.GetGuid(reader.GetOrdinal("UserId")),
            reader.GetString(reader.GetOrdinal("MethodType")),
            reader.GetBoolean(reader.GetOrdinal("IsEnabled")),
            reader.GetInt32(reader.GetOrdinal("SecretKeyVersion")),
            (byte[])reader["SecretCiphertext"],
            reader.IsDBNull(reader.GetOrdinal("LastAcceptedTimeStep"))
                ? null
                : reader.GetInt64(reader.GetOrdinal("LastAcceptedTimeStep")));
    }

    public async Task<UserLockoutState> GetOrCreateLockoutAsync(Guid userId, CancellationToken cancellationToken)
    {
        const string readSql = @"
SELECT TOP 1 UserId, FailedAttemptsInWindow, WindowStartUtc, LockedUntilUtc, LastFailureUtc
FROM otp.UserLockouts
WHERE UserId = @UserId;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using (var readCmd = new SqlCommand(readSql, connection))
        {
            readCmd.Parameters.AddWithValue("@UserId", userId);
            await using var reader = await readCmd.ExecuteReaderAsync(cancellationToken);
            if (await reader.ReadAsync(cancellationToken))
            {
                return new UserLockoutState(
                    reader.GetGuid(reader.GetOrdinal("UserId")),
                    reader.GetInt32(reader.GetOrdinal("FailedAttemptsInWindow")),
                    GetNullableUtcDateTimeOffset(reader, "WindowStartUtc"),
                    GetNullableUtcDateTimeOffset(reader, "LockedUntilUtc"),
                    GetNullableUtcDateTimeOffset(reader, "LastFailureUtc"));
            }
        }

        const string createSql = @"
INSERT INTO otp.UserLockouts (UserId, FailedAttemptsInWindow, UpdatedUtc)
VALUES (@UserId, 0, SYSUTCDATETIME());";

        await using (var createCmd = new SqlCommand(createSql, connection))
        {
            createCmd.Parameters.AddWithValue("@UserId", userId);
            await createCmd.ExecuteNonQueryAsync(cancellationToken);
        }

        return new UserLockoutState(userId, 0, null, null, null);
    }

    public async Task SaveLockoutAsync(UserLockoutState state, CancellationToken cancellationToken)
    {
        const string sql = @"
UPDATE otp.UserLockouts
SET FailedAttemptsInWindow = @FailedAttemptsInWindow,
    WindowStartUtc = @WindowStartUtc,
    LockedUntilUtc = @LockedUntilUtc,
    LastFailureUtc = @LastFailureUtc,
    UpdatedUtc = SYSUTCDATETIME()
WHERE UserId = @UserId;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserId", state.UserId);
        cmd.Parameters.AddWithValue("@FailedAttemptsInWindow", state.FailedAttemptsInWindow);
        cmd.Parameters.AddWithValue("@WindowStartUtc", (object?)state.WindowStartUtc?.UtcDateTime ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LockedUntilUtc", (object?)state.LockedUntilUtc?.UtcDateTime ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LastFailureUtc", (object?)state.LastFailureUtc?.UtcDateTime ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task UpdateLastAcceptedTimeStepAsync(Guid methodId, long timeStep, CancellationToken cancellationToken)
    {
        const string sql = @"
UPDATE otp.OtpSecrets
SET LastAcceptedTimeStep = @LastAcceptedTimeStep
WHERE MethodId = @MethodId;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@MethodId", methodId);
        cmd.Parameters.AddWithValue("@LastAcceptedTimeStep", timeStep);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
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
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand("otp.LogOtpAttempt", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        cmd.Parameters.AddWithValue("@UserId", (object?)user?.UserId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@UserPrincipalName", userPrincipalName);
        cmd.Parameters.AddWithValue("@MethodType", (object?)methodType ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@IsSuccess", isSuccess);
        cmd.Parameters.AddWithValue("@FailureReason", failureReason == OtpFailureReason.None ? DBNull.Value : failureReason.ToString().ToUpperInvariant());
        cmd.Parameters.AddWithValue("@ClientIp", (object?)clientIp ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@UserAgent", (object?)userAgent ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CorrelationId", (object?)correlationId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@AdfsActivityId", (object?)adfsActivityId ?? DBNull.Value);

        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task ResetUserMethodsAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken)
    {
        const string sql = @"
BEGIN TRANSACTION;

UPDATE m
SET m.IsEnabled = 0,
    m.DisabledUtc = SYSUTCDATETIME()
FROM otp.OtpMethods m
INNER JOIN otp.Users u ON u.UserId = m.UserId
WHERE u.UserPrincipalName = @TargetUserUpn;

UPDATE u
SET u.IsEnrolled = 0,
    u.UpdatedUtc = SYSUTCDATETIME()
FROM otp.Users u
WHERE u.UserPrincipalName = @TargetUserUpn;

INSERT INTO otp.AdminActions (AdminUpn, TargetUserUpn, ActionType, Reason)
VALUES (@AdminUpn, @TargetUserUpn, 'RESET_METHODS', @Reason);

COMMIT TRANSACTION;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@TargetUserUpn", targetUserUpn);
        cmd.Parameters.AddWithValue("@AdminUpn", adminUpn);
        cmd.Parameters.AddWithValue("@Reason", reason);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task UnlockUserAsync(string targetUserUpn, string adminUpn, string reason, CancellationToken cancellationToken)
    {
        const string sql = @"
BEGIN TRANSACTION;

UPDATE l
SET l.FailedAttemptsInWindow = 0,
    l.WindowStartUtc = NULL,
    l.LockedUntilUtc = NULL,
    l.LastFailureUtc = NULL,
    l.UpdatedUtc = SYSUTCDATETIME()
FROM otp.UserLockouts l
INNER JOIN otp.Users u ON u.UserId = l.UserId
WHERE u.UserPrincipalName = @TargetUserUpn;

INSERT INTO otp.AdminActions (AdminUpn, TargetUserUpn, ActionType, Reason)
VALUES (@AdminUpn, @TargetUserUpn, 'UNLOCK_USER', @Reason);

COMMIT TRANSACTION;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@TargetUserUpn", targetUserUpn);
        cmd.Parameters.AddWithValue("@AdminUpn", adminUpn);
        cmd.Parameters.AddWithValue("@Reason", reason);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task SaveEnrollmentAsync(string userPrincipalName, byte[] encryptedSecret, int keyVersion, CancellationToken cancellationToken)
    {
        const string sql = @"
DECLARE @UserId UNIQUEIDENTIFIER;
SELECT TOP 1 @UserId = UserId FROM otp.Users WHERE UserPrincipalName = @UserPrincipalName;

IF @UserId IS NULL
BEGIN
    SET @UserId = NEWID();
    INSERT INTO otp.Users (UserId, UserPrincipalName, IsEnrolled, IsActive)
    VALUES (@UserId, @UserPrincipalName, 0, 1);
END

DECLARE @MethodId UNIQUEIDENTIFIER = NEWID();

INSERT INTO otp.OtpMethods (MethodId, UserId, MethodType, IsPrimaryMethod, IsEnabled)
VALUES (@MethodId, @UserId, 'TOTP', 1, 1);

INSERT INTO otp.OtpSecrets (MethodId, SecretCiphertext, SecretKeyVersion)
VALUES (@MethodId, @SecretCiphertext, @SecretKeyVersion);

UPDATE otp.Users
SET IsEnrolled = 1,
    UpdatedUtc = SYSUTCDATETIME()
WHERE UserId = @UserId;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserPrincipalName", userPrincipalName);
        cmd.Parameters.AddWithValue("@SecretCiphertext", encryptedSecret);
        cmd.Parameters.AddWithValue("@SecretKeyVersion", keyVersion);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task SavePendingEnrollmentAsync(PendingEnrollmentState pendingEnrollment, CancellationToken cancellationToken)
    {
        const string sql = @"
MERGE otp.PendingEnrollments AS target
USING (SELECT @UserPrincipalName AS UserPrincipalName) AS source
ON target.UserPrincipalName = source.UserPrincipalName
WHEN MATCHED THEN
    UPDATE SET
        SecretBase32 = @SecretBase32,
        IdpName = @IdpName,
        AccountName = @AccountName,
        ExpiresUtc = @ExpiresUtc,
        UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (UserPrincipalName, SecretBase32, IdpName, AccountName, ExpiresUtc)
    VALUES (@UserPrincipalName, @SecretBase32, @IdpName, @AccountName, @ExpiresUtc);";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserPrincipalName", pendingEnrollment.UserPrincipalName);
        cmd.Parameters.AddWithValue("@SecretBase32", pendingEnrollment.SecretBase32);
        cmd.Parameters.AddWithValue("@IdpName", pendingEnrollment.IdpName);
        cmd.Parameters.AddWithValue("@AccountName", pendingEnrollment.AccountName);
        cmd.Parameters.AddWithValue("@ExpiresUtc", pendingEnrollment.ExpiresUtc.UtcDateTime);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<PendingEnrollmentState?> GetPendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT TOP 1 UserPrincipalName, SecretBase32, IdpName, AccountName, ExpiresUtc
FROM otp.PendingEnrollments
WHERE UserPrincipalName = @UserPrincipalName;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserPrincipalName", userPrincipalName);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new PendingEnrollmentState(
            reader.GetString(reader.GetOrdinal("UserPrincipalName")),
            reader.GetString(reader.GetOrdinal("SecretBase32")),
            reader.GetString(reader.GetOrdinal("IdpName")),
            reader.GetString(reader.GetOrdinal("AccountName")),
            GetUtcDateTimeOffset(reader, "ExpiresUtc"));
    }

    public async Task DeletePendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = @"
DELETE FROM otp.PendingEnrollments
WHERE UserPrincipalName = @UserPrincipalName;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UserPrincipalName", userPrincipalName);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<int> DeleteExpiredPendingEnrollmentsAsync(DateTimeOffset utcNow, CancellationToken cancellationToken)
    {
        const string sql = @"
DELETE FROM otp.PendingEnrollments
WHERE ExpiresUtc <= @UtcNow;";

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@UtcNow", utcNow.UtcDateTime);
        return await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    private static DateTimeOffset? GetNullableUtcDateTimeOffset(SqlDataReader reader, string columnName)
    {
        var ordinal = reader.GetOrdinal(columnName);
        if (reader.IsDBNull(ordinal))
        {
            return null;
        }

        return GetUtcDateTimeOffset(reader, ordinal, columnName);
    }

    private static DateTimeOffset GetUtcDateTimeOffset(SqlDataReader reader, string columnName)
    {
        var ordinal = reader.GetOrdinal(columnName);
        return GetUtcDateTimeOffset(reader, ordinal, columnName);
    }

    private static DateTimeOffset GetUtcDateTimeOffset(SqlDataReader reader, int ordinal, string columnName)
    {
        var value = reader.GetValue(ordinal);
        return value switch
        {
            DateTimeOffset dto => dto.ToUniversalTime(),
            DateTime dt => dt.Kind switch
            {
                DateTimeKind.Utc => new DateTimeOffset(dt),
                DateTimeKind.Local => new DateTimeOffset(dt.ToUniversalTime(), TimeSpan.Zero),
                _ => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc))
            },
            _ => throw new InvalidOperationException($"Column '{columnName}' must be DateTime or DateTimeOffset, but was '{value.GetType().FullName}'.")
        };
    }
}
