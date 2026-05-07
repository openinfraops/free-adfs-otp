# Runbook local

## Prerequis

- .NET SDK 8.x
- Build tools .NET Framework pour net48 (si compilation adapter)
- SQL Server 2019+

Si la commande `dotnet` n'est pas reconnue juste apres installation, relancer VS Code/terminal ou utiliser temporairement:

- `C:\Program Files\dotnet\dotnet.exe`

## 1. Base SQL

1. Creer la base `FreeAdfsOtp`
2. Executer [sql/001_init.sql](../sql/001_init.sql)
3. Executer [sql/002_pending_enrollments.sql](../sql/002_pending_enrollments.sql)

## 2. Cle de chiffrement

Generer une cle AES-256 base64 (32 bytes):

- PowerShell:
  - `[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }))`

Mettre la valeur dans:

- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `SecretProtection:MasterKey`

Configurer aussi une cle admin API longue et aleatoire:

- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `AdminAuth:ApiKey`
- [src/FreeAdfsOtp.AdminPortal/appsettings.json](../src/FreeAdfsOtp.AdminPortal/appsettings.json) > `OtpApi:AdminApiKey`

Parametres de durcissement disponibles:

- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `RateLimiting:*`
- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `Enrollment:CleanupIntervalMinutes`

## 3. Lancer API

- `dotnet run --project src/FreeAdfsOtp.Api`

## 3bis. Restore/Build

Le repository inclut [NuGet.Config](../NuGet.Config) avec la source nuget.org.

- `dotnet restore freeADFSOtp.sln`
- `dotnet build freeADFSOtp.sln -c Debug`

Generation des ZIP de livraison:

- `./deploy/package-artifacts.ps1 -Configuration Release -DotnetPath "C:\Program Files\dotnet\dotnet.exe"`

Generation versionnee type release:

- `./deploy/package-artifacts.ps1 -Configuration Release -DotnetPath "C:\Program Files\dotnet\dotnet.exe" -PackagePrefix "freeADFSOtp-v1.0.0" -CreateBundle`

## 4. Lancer portails

- `dotnet run --project src/FreeAdfsOtp.EnrollmentPortal`
- `dotnet run --project src/FreeAdfsOtp.AdminPortal`

## 5. Test rapide

1. Enrollment:
   - Ouvrir `/enroll`
   - Renseigner UPN + `Nom IDP` + `Nom du compte`
   - Scanner le QR code genere dans l'app OTP
   - Verifier que le libelle affiche `IDP:Compte`
   - Verifier code
2. Validation OTP:
   - POST `/otp/validate`
3. Lockout:
   - Soumettre mauvais code 5 fois
   - verifier `otp.UserLockouts`
4. Admin reset/unlock:
   - utiliser portail admin
   - verifier `otp.AdminActions`

## 6. AD FS

Suivre [docs/adfs-integration.md](adfs-integration.md) pour brancher le provider.
