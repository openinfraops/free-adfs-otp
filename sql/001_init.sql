/*
  SQL Server initial schema for OTP + AD FS integration.
  Target: SQL Server 2019+
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'otp')
BEGIN
    EXEC('CREATE SCHEMA otp');
END
GO

CREATE TABLE otp.Users (
    UserId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    UserPrincipalName NVARCHAR(256) NOT NULL,
    DisplayName NVARCHAR(256) NULL,
    IsEnrolled BIT NOT NULL DEFAULT 0,
    IsActive BIT NOT NULL DEFAULT 1,
    CreatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Users PRIMARY KEY (UserId),
    CONSTRAINT UQ_Users_UserPrincipalName UNIQUE (UserPrincipalName)
);
GO

CREATE TABLE otp.OtpMethods (
    MethodId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    UserId UNIQUEIDENTIFIER NOT NULL,
    MethodType NVARCHAR(50) NOT NULL, /* TOTP, EMAIL_OTP, SMS_OTP */
    IsPrimaryMethod BIT NOT NULL DEFAULT 1,
    IsEnabled BIT NOT NULL DEFAULT 1,
    EnrolledUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    DisabledUtc DATETIME2(3) NULL,
    CONSTRAINT PK_OtpMethods PRIMARY KEY (MethodId),
    CONSTRAINT FK_OtpMethods_Users FOREIGN KEY (UserId) REFERENCES otp.Users(UserId)
);
GO

CREATE TABLE otp.OtpSecrets (
    SecretId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    MethodId UNIQUEIDENTIFIER NOT NULL,
    SecretCiphertext VARBINARY(MAX) NOT NULL,
    SecretKeyVersion INT NOT NULL,
    LastAcceptedTimeStep BIGINT NULL,
    CreatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    RotatedUtc DATETIME2(3) NULL,
    CONSTRAINT PK_OtpSecrets PRIMARY KEY (SecretId),
    CONSTRAINT FK_OtpSecrets_OtpMethods FOREIGN KEY (MethodId) REFERENCES otp.OtpMethods(MethodId)
);
GO

CREATE TABLE otp.UserLockouts (
    LockoutId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    UserId UNIQUEIDENTIFIER NOT NULL,
    FailedAttemptsInWindow INT NOT NULL DEFAULT 0,
    WindowStartUtc DATETIME2(3) NULL,
    LockedUntilUtc DATETIME2(3) NULL,
    LastFailureUtc DATETIME2(3) NULL,
    UpdatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_UserLockouts PRIMARY KEY (LockoutId),
    CONSTRAINT UQ_UserLockouts_User UNIQUE (UserId),
    CONSTRAINT FK_UserLockouts_Users FOREIGN KEY (UserId) REFERENCES otp.Users(UserId)
);
GO

CREATE TABLE otp.OtpAttempts (
    AttemptId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    UserId UNIQUEIDENTIFIER NULL,
    UserPrincipalName NVARCHAR(256) NULL,
    MethodType NVARCHAR(50) NULL,
    AttemptUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    IsSuccess BIT NOT NULL,
    FailureReason NVARCHAR(100) NULL, /* INVALID_CODE, LOCKED, NOT_ENROLLED, EXPIRED, REPLAY */
    ClientIp NVARCHAR(64) NULL,
    UserAgent NVARCHAR(512) NULL,
    CorrelationId UNIQUEIDENTIFIER NULL,
    AdfsActivityId UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_OtpAttempts PRIMARY KEY (AttemptId),
    CONSTRAINT FK_OtpAttempts_Users FOREIGN KEY (UserId) REFERENCES otp.Users(UserId)
);
GO

CREATE TABLE otp.AdminActions (
    ActionId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    ActionUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    AdminUpn NVARCHAR(256) NOT NULL,
    TargetUserUpn NVARCHAR(256) NOT NULL,
    ActionType NVARCHAR(100) NOT NULL, /* RESET_METHODS, UNLOCK_USER, FORCE_REENROLL */
    Reason NVARCHAR(512) NOT NULL,
    CorrelationId UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_AdminActions PRIMARY KEY (ActionId)
);
GO

CREATE TABLE otp.Settings (
    SettingKey NVARCHAR(100) NOT NULL,
    SettingValue NVARCHAR(4000) NOT NULL,
    UpdatedUtc DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Settings PRIMARY KEY (SettingKey)
);
GO

INSERT INTO otp.Settings (SettingKey, SettingValue) VALUES
('Otp:TotpDigits', '6'),
('Otp:TotpStepSeconds', '30'),
('Otp:TotpAllowedSkewSteps', '1'),
('Lockout:MaxFailedAttempts', '5'),
('Lockout:FailedWindowMinutes', '10'),
('Lockout:LockoutMinutes', '15');
GO

CREATE INDEX IX_OtpAttempts_AttemptUtc ON otp.OtpAttempts(AttemptUtc DESC);
CREATE INDEX IX_OtpAttempts_UserPrincipalName ON otp.OtpAttempts(UserPrincipalName);
CREATE INDEX IX_OtpMethods_UserId ON otp.OtpMethods(UserId);
GO

/*
  Minimal helper stored procedures
*/

CREATE OR ALTER PROCEDURE otp.GetUserByUpn
    @UserPrincipalName NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        u.UserId,
        u.UserPrincipalName,
        u.IsEnrolled,
        u.IsActive
    FROM otp.Users u
    WHERE u.UserPrincipalName = @UserPrincipalName;
END
GO

CREATE OR ALTER PROCEDURE otp.LogOtpAttempt
    @UserId UNIQUEIDENTIFIER = NULL,
    @UserPrincipalName NVARCHAR(256) = NULL,
    @MethodType NVARCHAR(50) = NULL,
    @IsSuccess BIT,
    @FailureReason NVARCHAR(100) = NULL,
    @ClientIp NVARCHAR(64) = NULL,
    @UserAgent NVARCHAR(512) = NULL,
    @CorrelationId UNIQUEIDENTIFIER = NULL,
    @AdfsActivityId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO otp.OtpAttempts (
        UserId,
        UserPrincipalName,
        MethodType,
        IsSuccess,
        FailureReason,
        ClientIp,
        UserAgent,
        CorrelationId,
        AdfsActivityId
    )
    VALUES (
        @UserId,
        @UserPrincipalName,
        @MethodType,
        @IsSuccess,
        @FailureReason,
        @ClientIp,
        @UserAgent,
        @CorrelationId,
        @AdfsActivityId
    );
END
GO
