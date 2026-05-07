/*
  Adds SQL-backed pending enrollment storage for distributed API instances.
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('otp.PendingEnrollments', 'U') IS NULL
BEGIN
    CREATE TABLE otp.PendingEnrollments (
        PendingEnrollmentId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        UserPrincipalName NVARCHAR(256) NOT NULL,
        SecretBase32 NVARCHAR(128) NOT NULL,
        IdpName NVARCHAR(128) NOT NULL,
        AccountName NVARCHAR(256) NOT NULL,
        ExpiresUtc DATETIME2(3) NOT NULL,
        CreatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        UpdatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_PendingEnrollments PRIMARY KEY (PendingEnrollmentId),
        CONSTRAINT UQ_PendingEnrollments_UserPrincipalName UNIQUE (UserPrincipalName)
    );
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_PendingEnrollments_ExpiresUtc'
      AND object_id = OBJECT_ID('otp.PendingEnrollments')
)
BEGIN
    CREATE INDEX IX_PendingEnrollments_ExpiresUtc ON otp.PendingEnrollments(ExpiresUtc);
END
GO
