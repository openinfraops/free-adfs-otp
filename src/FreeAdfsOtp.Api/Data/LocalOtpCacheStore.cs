using FreeAdfsOtp.Api.Security;
using FreeAdfsOtp.Core.Models;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;

namespace FreeAdfsOtp.Api.Data;

public sealed class LocalOtpCacheStore
{
    private readonly string _connectionString;
    private readonly LocalNodeCacheCipher _cipher;

    public LocalOtpCacheStore(IOptions<LocalCacheOptions> options, LocalNodeCacheCipher cipher)
    {
        _cipher = cipher;
        var databasePath = options.Value.DatabasePath;
        if (string.IsNullOrWhiteSpace(databasePath))
        {
            throw new InvalidOperationException("LocalCache:DatabasePath is required when cache is enabled.");
        }

        var fullPath = Path.GetFullPath(databasePath);
        var directory = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _connectionString = new SqliteConnectionStringBuilder { DataSource = fullPath }.ToString();
        InitializeSchema();
    }

    public async Task<OtpUser?> GetUserByUpnAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT user_id, user_principal_name, is_enrolled, is_active
FROM cached_users
WHERE user_principal_name = $upn;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$upn", userPrincipalName);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new OtpUser(
            Guid.Parse(reader.GetString(0)),
            reader.GetString(1),
            reader.GetBoolean(2),
            reader.GetBoolean(3));
    }

    public async Task UpsertUserAsync(OtpUser user, CancellationToken cancellationToken)
    {
        const string sql = @"
INSERT INTO cached_users (user_id, user_principal_name, is_enrolled, is_active, updated_utc)
VALUES ($userId, $upn, $isEnrolled, $isActive, $updatedUtc)
ON CONFLICT(user_principal_name) DO UPDATE SET
    user_id = excluded.user_id,
    is_enrolled = excluded.is_enrolled,
    is_active = excluded.is_active,
    updated_utc = excluded.updated_utc;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$userId", user.UserId.ToString("D"));
        cmd.Parameters.AddWithValue("$upn", user.UserPrincipalName);
        cmd.Parameters.AddWithValue("$isEnrolled", user.IsEnrolled ? 1 : 0);
        cmd.Parameters.AddWithValue("$isActive", user.IsActive ? 1 : 0);
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task DeleteUserByUpnAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = "DELETE FROM cached_users WHERE user_principal_name = $upn;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$upn", userPrincipalName);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<OtpMethod?> GetPrimaryMethodAsync(Guid userId, CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT method_id, user_id, method_type, is_enabled, secret_key_version, secret_ciphertext, last_accepted_time_step
FROM cached_methods
WHERE user_id = $userId
  AND is_primary_method = 1
LIMIT 1;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$userId", userId.ToString("D"));

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        var protectedSecretBlob = (byte[])reader[5];
        var sqlCipherText = _cipher.DecryptBytes(protectedSecretBlob);

        return new OtpMethod(
            Guid.Parse(reader.GetString(0)),
            Guid.Parse(reader.GetString(1)),
            reader.GetString(2),
            reader.GetBoolean(3),
            reader.GetInt32(4),
            sqlCipherText,
            reader.IsDBNull(6) ? null : reader.GetInt64(6));
    }

    public async Task UpsertMethodAsync(OtpMethod method, CancellationToken cancellationToken)
    {
        const string sql = @"
INSERT INTO cached_methods (
    method_id,
    user_id,
    method_type,
    is_primary_method,
    is_enabled,
    secret_key_version,
    secret_ciphertext,
    last_accepted_time_step,
    updated_utc)
VALUES (
    $methodId,
    $userId,
    $methodType,
    1,
    $isEnabled,
    $secretKeyVersion,
    $secretCiphertext,
    $lastAcceptedTimeStep,
    $updatedUtc)
ON CONFLICT(method_id) DO UPDATE SET
    user_id = excluded.user_id,
    method_type = excluded.method_type,
    is_primary_method = excluded.is_primary_method,
    is_enabled = excluded.is_enabled,
    secret_key_version = excluded.secret_key_version,
    secret_ciphertext = excluded.secret_ciphertext,
    last_accepted_time_step = excluded.last_accepted_time_step,
    updated_utc = excluded.updated_utc;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);

        cmd.Parameters.AddWithValue("$methodId", method.MethodId.ToString("D"));
        cmd.Parameters.AddWithValue("$userId", method.UserId.ToString("D"));
        cmd.Parameters.AddWithValue("$methodType", method.MethodType);
        cmd.Parameters.AddWithValue("$isEnabled", method.IsEnabled ? 1 : 0);
        cmd.Parameters.AddWithValue("$secretKeyVersion", method.SecretKeyVersion);
        cmd.Parameters.AddWithValue("$secretCiphertext", _cipher.EncryptBytes(method.SecretCiphertext));
        cmd.Parameters.AddWithValue("$lastAcceptedTimeStep", (object?)method.LastAcceptedTimeStep ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));

        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task UpdateLastAcceptedTimeStepAsync(Guid methodId, long timeStep, CancellationToken cancellationToken)
    {
        const string sql = @"
UPDATE cached_methods
SET last_accepted_time_step = $timeStep,
    updated_utc = $updatedUtc
WHERE method_id = $methodId;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$methodId", methodId.ToString("D"));
        cmd.Parameters.AddWithValue("$timeStep", timeStep);
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<UserLockoutState> GetOrCreateLockoutAsync(Guid userId, CancellationToken cancellationToken)
    {
        const string selectSql = @"
SELECT user_id, failed_attempts_in_window, window_start_utc, locked_until_utc, last_failure_utc
FROM cached_lockouts
WHERE user_id = $userId;";

        await using var connection = await OpenAsync(cancellationToken);
        await using (var select = new SqliteCommand(selectSql, connection))
        {
            select.Parameters.AddWithValue("$userId", userId.ToString("D"));
            await using var reader = await select.ExecuteReaderAsync(cancellationToken);
            if (await reader.ReadAsync(cancellationToken))
            {
                return new UserLockoutState(
                    Guid.Parse(reader.GetString(0)),
                    reader.GetInt32(1),
                    ParseNullableDateTimeOffset(reader, 2),
                    ParseNullableDateTimeOffset(reader, 3),
                    ParseNullableDateTimeOffset(reader, 4));
            }
        }

        var initial = new UserLockoutState(userId, 0, null, null, null);
        await SaveLockoutAsync(initial, cancellationToken);
        return initial;
    }

    public async Task SaveLockoutAsync(UserLockoutState state, CancellationToken cancellationToken)
    {
        const string sql = @"
INSERT INTO cached_lockouts (
    user_id,
    failed_attempts_in_window,
    window_start_utc,
    locked_until_utc,
    last_failure_utc,
    updated_utc)
VALUES (
    $userId,
    $failedAttempts,
    $windowStart,
    $lockedUntil,
    $lastFailure,
    $updatedUtc)
ON CONFLICT(user_id) DO UPDATE SET
    failed_attempts_in_window = excluded.failed_attempts_in_window,
    window_start_utc = excluded.window_start_utc,
    locked_until_utc = excluded.locked_until_utc,
    last_failure_utc = excluded.last_failure_utc,
    updated_utc = excluded.updated_utc;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);

        cmd.Parameters.AddWithValue("$userId", state.UserId.ToString("D"));
        cmd.Parameters.AddWithValue("$failedAttempts", state.FailedAttemptsInWindow);
        cmd.Parameters.AddWithValue("$windowStart", (object?)state.WindowStartUtc?.ToString("O") ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$lockedUntil", (object?)state.LockedUntilUtc?.ToString("O") ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$lastFailure", (object?)state.LastFailureUtc?.ToString("O") ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task UpsertPendingEnrollmentAsync(PendingEnrollmentState pendingEnrollment, CancellationToken cancellationToken)
    {
        const string sql = @"
INSERT INTO cached_pending_enrollments (
    user_principal_name,
    secret_base32,
    idp_name,
    account_name,
    expires_utc,
    updated_utc)
VALUES (
    $upn,
    $secretBase32,
    $idpName,
    $accountName,
    $expiresUtc,
    $updatedUtc)
ON CONFLICT(user_principal_name) DO UPDATE SET
    secret_base32 = excluded.secret_base32,
    idp_name = excluded.idp_name,
    account_name = excluded.account_name,
    expires_utc = excluded.expires_utc,
    updated_utc = excluded.updated_utc;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);

        cmd.Parameters.AddWithValue("$upn", pendingEnrollment.UserPrincipalName);
        cmd.Parameters.AddWithValue("$secretBase32", _cipher.EncryptString(pendingEnrollment.SecretBase32));
        cmd.Parameters.AddWithValue("$idpName", pendingEnrollment.IdpName);
        cmd.Parameters.AddWithValue("$accountName", pendingEnrollment.AccountName);
        cmd.Parameters.AddWithValue("$expiresUtc", pendingEnrollment.ExpiresUtc.ToString("O"));
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<PendingEnrollmentState?> GetPendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = @"
SELECT user_principal_name, secret_base32, idp_name, account_name, expires_utc
FROM cached_pending_enrollments
WHERE user_principal_name = $upn;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$upn", userPrincipalName);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new PendingEnrollmentState(
            reader.GetString(0),
            _cipher.DecryptString(reader.GetString(1)),
            reader.GetString(2),
            reader.GetString(3),
            DateTimeOffset.Parse(reader.GetString(4)));
    }

    public async Task DeletePendingEnrollmentAsync(string userPrincipalName, CancellationToken cancellationToken)
    {
        const string sql = "DELETE FROM cached_pending_enrollments WHERE user_principal_name = $upn;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$upn", userPrincipalName);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<int> DeleteExpiredPendingEnrollmentsAsync(DateTimeOffset utcNow, CancellationToken cancellationToken)
    {
        const string sql = "DELETE FROM cached_pending_enrollments WHERE expires_utc <= $utcNow;";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$utcNow", utcNow.ToString("O"));
        return await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task MarkUserMethodsResetAsync(string targetUserUpn, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
    await using var tx = (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);

        var disableMethods = new SqliteCommand(@"
UPDATE cached_methods
SET is_enabled = 0,
    updated_utc = $updatedUtc
WHERE user_id = (SELECT user_id FROM cached_users WHERE user_principal_name = $upn LIMIT 1);", connection, tx);
        disableMethods.Parameters.AddWithValue("$upn", targetUserUpn);
        disableMethods.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await disableMethods.ExecuteNonQueryAsync(cancellationToken);

        var updateUser = new SqliteCommand(@"
UPDATE cached_users
SET is_enrolled = 0,
    updated_utc = $updatedUtc
WHERE user_principal_name = $upn;", connection, tx);
        updateUser.Parameters.AddWithValue("$upn", targetUserUpn);
        updateUser.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await updateUser.ExecuteNonQueryAsync(cancellationToken);

        await tx.CommitAsync(cancellationToken);
    }

    public async Task UnlockUserAsync(string targetUserUpn, CancellationToken cancellationToken)
    {
        const string sql = @"
UPDATE cached_lockouts
SET failed_attempts_in_window = 0,
    window_start_utc = NULL,
    locked_until_utc = NULL,
    last_failure_utc = NULL,
    updated_utc = $updatedUtc
WHERE user_id = (SELECT user_id FROM cached_users WHERE user_principal_name = $upn LIMIT 1);";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);
        cmd.Parameters.AddWithValue("$upn", targetUserUpn);
        cmd.Parameters.AddWithValue("$updatedUtc", DateTimeOffset.UtcNow.ToString("O"));
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
        const string sql = @"
INSERT INTO cached_otp_attempts (
    attempt_utc,
    user_id,
    user_principal_name,
    method_type,
    is_success,
    failure_reason,
    client_ip,
    user_agent,
    correlation_id,
    adfs_activity_id)
VALUES (
    $attemptUtc,
    $userId,
    $upn,
    $methodType,
    $isSuccess,
    $failureReason,
    $clientIp,
    $userAgent,
    $correlationId,
    $adfsActivityId);";

        await using var connection = await OpenAsync(cancellationToken);
        await using var cmd = new SqliteCommand(sql, connection);

        cmd.Parameters.AddWithValue("$attemptUtc", DateTimeOffset.UtcNow.ToString("O"));
        cmd.Parameters.AddWithValue("$userId", (object?)user?.UserId.ToString("D") ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$upn", userPrincipalName);
        cmd.Parameters.AddWithValue("$methodType", (object?)methodType ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$isSuccess", isSuccess ? 1 : 0);
        cmd.Parameters.AddWithValue("$failureReason", failureReason == OtpFailureReason.None ? DBNull.Value : failureReason.ToString().ToUpperInvariant());
        cmd.Parameters.AddWithValue("$clientIp", (object?)clientIp ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$userAgent", (object?)userAgent ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$correlationId", (object?)correlationId?.ToString("D") ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$adfsActivityId", (object?)adfsActivityId?.ToString("D") ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
    }

    private static DateTimeOffset? ParseNullableDateTimeOffset(SqliteDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal))
        {
            return null;
        }

        return DateTimeOffset.Parse(reader.GetString(ordinal));
    }

    private async Task<SqliteConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    private void InitializeSchema()
    {
        using var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var cmd = connection.CreateCommand();
        cmd.CommandText = @"
CREATE TABLE IF NOT EXISTS cached_users (
    user_id TEXT NOT NULL,
    user_principal_name TEXT NOT NULL PRIMARY KEY,
    is_enrolled INTEGER NOT NULL,
    is_active INTEGER NOT NULL,
    updated_utc TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cached_methods (
    method_id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    method_type TEXT NOT NULL,
    is_primary_method INTEGER NOT NULL,
    is_enabled INTEGER NOT NULL,
    secret_key_version INTEGER NOT NULL,
    secret_ciphertext BLOB NOT NULL,
    last_accepted_time_step INTEGER NULL,
    updated_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_cached_methods_user_id ON cached_methods(user_id);

CREATE TABLE IF NOT EXISTS cached_lockouts (
    user_id TEXT NOT NULL PRIMARY KEY,
    failed_attempts_in_window INTEGER NOT NULL,
    window_start_utc TEXT NULL,
    locked_until_utc TEXT NULL,
    last_failure_utc TEXT NULL,
    updated_utc TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cached_pending_enrollments (
    user_principal_name TEXT NOT NULL PRIMARY KEY,
    secret_base32 TEXT NOT NULL,
    idp_name TEXT NOT NULL,
    account_name TEXT NOT NULL,
    expires_utc TEXT NOT NULL,
    updated_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_cached_pending_enrollments_expires_utc ON cached_pending_enrollments(expires_utc);

CREATE TABLE IF NOT EXISTS cached_otp_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    attempt_utc TEXT NOT NULL,
    user_id TEXT NULL,
    user_principal_name TEXT NULL,
    method_type TEXT NULL,
    is_success INTEGER NOT NULL,
    failure_reason TEXT NULL,
    client_ip TEXT NULL,
    user_agent TEXT NULL,
    correlation_id TEXT NULL,
    adfs_activity_id TEXT NULL
);
";
        cmd.ExecuteNonQuery();
    }
}
