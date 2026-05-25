# Runbook local

## Prerequis

- .NET SDK 8.x
- Build tools .NET Framework pour net47 (si compilation adapter)
- SQL Server 2019+

Composants applicatifs:

- API OTP (`src/FreeAdfsOtp.Api`)
- Enrollment Portal (`src/FreeAdfsOtp.EnrollmentPortal`)
- Admin Portal (`src/FreeAdfsOtp.AdminPortal`)

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

Parametres de resilience disponibles:

- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `LocalCache:*`
- [src/FreeAdfsOtp.Api/appsettings.json](../src/FreeAdfsOtp.Api/appsettings.json) > `SqlResilience:*`

Important:

- `SecretProtection:MasterKey` doit etre identique entre API et adapter AD FS en mode `SqlDirect`

## 3. Lancer API

- `dotnet run --project src/FreeAdfsOtp.Api`

Endpoints exposes:

- `GET /health`
- `GET /otp/enrollment-status/{upn}`
- `POST /otp/validate`
- `POST /enrollment/start`
- `POST /enrollment/verify`
- `POST /admin/users/{upn}/reset-methods` (header `X-Admin-ApiKey` requis)
- `POST /admin/users/{upn}/unlock` (header `X-Admin-ApiKey` requis)

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

Configuration recommandee du portail admin:

- [src/FreeAdfsOtp.AdminPortal/appsettings.json](../src/FreeAdfsOtp.AdminPortal/appsettings.json)
   - `OtpApi:BaseUrl`: URL de l'API OTP
   - `OtpApi:AdminApiKey`: cle API admin (doit correspondre a `AdminAuth:ApiKey` cote API)
   - `Authentication:ForceNegotiateHandler`: cle optionnelle (non presente par defaut), laisser `false` sous IIS, passer a `true` uniquement en auto-hebergement si necessaire

Securite d'acces portail admin:

1. L'utilisateur doit etre authentifie en Windows
2. L'utilisateur doit appartenir au groupe local `Administrators` du serveur
3. Sous IIS, activer `Windows Authentication` et desactiver `Anonymous Authentication`
4. Le portail applique aussi token CSRF + verification same-origin sur les POST

Configuration recommandee du portail d'enrôlement:

- [src/FreeAdfsOtp.EnrollmentPortal/appsettings.json](../src/FreeAdfsOtp.EnrollmentPortal/appsettings.json)
   - `Enrollment:IdpName`: identifiant fournisseur affiche dans le label OTP
   - `Enrollment:PhoneIssuerName`: nom affiche dans l'application OTP (issuer). Si vide, `Enrollment:IdpName` est utilise.
   - `Enrollment:AllowedWindowsDomain`: nom NetBIOS autorise (ex: `CONTOSO`)
   - `Enrollment:DefaultUpnSuffix`: suffixe UPN pour convertir `DOMAINE\utilisateur` en `utilisateur@domaine`
   - `Enrollment:AllowManualUpn`: laisser `false` en production
   - `Authentication:ForceNegotiateHandler`: cle optionnelle (meme comportement que portail admin)

Sous IIS (recommande en production):

1. Activer `Windows Authentication` sur le site
2. Desactiver `Anonymous Authentication`
3. Forcer HTTPS

Le portail enrollement applique aussi:

- token CSRF sur POST `/enroll/start` et `/enroll/verify`
- controles same-origin (`Sec-Fetch-Site`, `Origin`, `Referer`)
- en-tetes de securite HTTP (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Content-Security-Policy`)

## 5. Test rapide

1. Enrollment:
   - Ouvrir `/enroll`
   - Verifier que l'utilisateur est detecte automatiquement via la session Windows
   - Renseigner uniquement le libelle compte (optionnel)
   - Scanner le QR code genere dans l'app OTP
   - Verifier que le libelle affiche `IDP:Compte`
   - Verifier code
2. Validation OTP:
   - POST `/otp/validate`
   - verifier le retour HTTP `200` + payload de resultat OTP
3. Lockout:
   - Soumettre mauvais code 5 fois
   - verifier `otp.UserLockouts`
4. Admin reset/unlock:
   - utiliser portail admin
   - verifier `otp.AdminActions`
5. Pending enrollment:
   - lancer un start sans verify
   - verifier `otp.PendingEnrollments`
   - attendre expiration puis verifier purge automatique

## 6. AD FS

Suivre [docs/adfs-integration.md](adfs-integration.md) pour brancher le provider.

## 7. Mode degrade SQL (optionnel)

Si `LocalCache:Enabled=true`:

1. L'API maintient un cache local des donnees OTP
2. En cas d'indisponibilite SQL, la validation OTP peut basculer temporairement en lecture cache
3. Le retour SQL est sonde periodiquement (`SqlResilience:ProbeIntervalSeconds`)
4. La fenetre de bypass SQL est controlee par `SqlResilience:DegradedModeWindowSeconds`
