# freeADFSOtp

freeADFSOtp est une solution OTP pour AD FS 2019/2022+ avec backend SQL Server. Le projet vise un déploiement on-premise, avec enrôlement utilisateur, administration des méthodes OTP, audit des usages, lockout paramétrable et intégration AD FS en authentification secondaire puis primaire.

## Fonctionnalités

- OTP TOTP avec validation côté API
- Intégration AD FS pour MFA, avec base runtime pour provider officiel
- Redirection vers enrôlement si l'utilisateur n'est pas encore enrôlé
- Génération de QR code pour provisioning mobile
- Libellé téléphone au format `IDP:Compte`
- Reset des méthodes OTP et déblocage utilisateur côté admin
- Journalisation des succès, échecs et lockouts
- Lockout paramétrable
- Stockage SQL des enrollments pending pour support multi-instance
- Rate limiting IP/UPN sur les endpoints sensibles
- Nettoyage automatique des enrollments expirés

## Architecture

Le dépôt contient cinq briques principales:

- [src/FreeAdfsOtp.Core](src/FreeAdfsOtp.Core): logique métier OTP, TOTP, lockout, contrats
- [src/FreeAdfsOtp.Api](src/FreeAdfsOtp.Api): API ASP.NET Core pour validation, enrôlement, admin et sécurité
- [src/FreeAdfsOtp.EnrollmentPortal](src/FreeAdfsOtp.EnrollmentPortal): portail web d'enrôlement
- [src/FreeAdfsOtp.AdminPortal](src/FreeAdfsOtp.AdminPortal): portail web d'administration
- [src/FreeAdfsOtp.AdfsAdapter](src/FreeAdfsOtp.AdfsAdapter): adapter AD FS et runtime serveur sous compilation conditionnelle

Compléments de projet:

- [sql](sql): scripts SQL d'initialisation et migrations
- [docs](docs): architecture, flux, plan MVP, runbooks
- [deploy/adfs](deploy/adfs): scripts de build, déploiement, rollback et policy AD FS

Vue détaillée: [docs/architecture.md](docs/architecture.md)

## Démarrage rapide

Prérequis:

- .NET SDK 8
- SQL Server 2019+
- Build tools .NET Framework si compilation adapter AD FS

Étapes locales:

1. Créer la base `FreeAdfsOtp`.
2. Exécuter [sql/001_init.sql](sql/001_init.sql).
3. Exécuter [sql/002_pending_enrollments.sql](sql/002_pending_enrollments.sql).
4. Renseigner la clé de chiffrement et la clé admin API dans [src/FreeAdfsOtp.Api/appsettings.json](src/FreeAdfsOtp.Api/appsettings.json).
5. Renseigner la même clé admin dans [src/FreeAdfsOtp.AdminPortal/appsettings.json](src/FreeAdfsOtp.AdminPortal/appsettings.json).
6. Restaurer et compiler la solution.
7. Lancer l'API et les portails.

Commandes:

```powershell
dotnet restore freeADFSOtp.sln
dotnet build freeADFSOtp.sln -c Debug
dotnet run --project src/FreeAdfsOtp.Api
dotnet run --project src/FreeAdfsOtp.EnrollmentPortal
dotnet run --project src/FreeAdfsOtp.AdminPortal
```

Guide détaillé: [docs/runbook-local.md](docs/runbook-local.md)

## Enrôlement TOTP

Le portail d'enrôlement génère:

- un secret Base32
- une URI `otpauth://`
- un QR code PNG affichable dans le navigateur
- un libellé téléphone au format `IDP:Compte`

Exemple de libellé:

- `ContosoIDP:user@contoso.com`

## Sécurité implémentée

- chiffrement AES des secrets OTP côté application
- anti-replay TOTP via `LastAcceptedTimeStep`
- lockout utilisateur paramétrable
- protection minimale des endpoints admin via header `X-Admin-ApiKey`
- rate limiting par IP et par UPN sur les endpoints critiques
- nettoyage automatique des enrollments expirés

Points restant à traiter avant production complète:

- externalisation de la clé maître hors `appsettings.json`
- authentification forte admin avec RBAC au lieu d'une simple API key
- batterie de tests automatisés plus complète
- validation finale du runtime AD FS sur ferme cible

## Déploiement AD FS

Le déploiement AD FS est prévu pour être exécuté sur les serveurs cibles, avec assembly signé, GAC, enregistrement du provider et configuration MFA.

Entrées principales:

- [deploy/adfs/README.md](deploy/adfs/README.md)
- [deploy/adfs/00-deploy-provider.ps1](deploy/adfs/00-deploy-provider.ps1)
- [deploy/adfs/99-rollback-provider.ps1](deploy/adfs/99-rollback-provider.ps1)

Le runtime AD FS officiel est compilé avec la constante `ADFS_SERVER` et nécessite `Microsoft.IdentityServer.Web.dll` disponible sur serveur AD FS.

## CI GitHub

Une pipeline GitHub Actions est fournie dans [/.github/workflows/ci.yml](.github/workflows/ci.yml).

Elle exécute:

- restore NuGet
- build Release de la solution sur runner Windows
- exécution conditionnelle des tests si des projets `*Tests.csproj` sont ajoutés plus tard
- publication des artefacts de build et des résultats de tests

Note: la CI compile la solution portable du dépôt. Le runtime AD FS serveur nécessitant `Microsoft.IdentityServer.Web.dll` reste destiné au build sur serveur ou environnement disposant de cette DLL.

## État du projet

Le dépôt contient aujourd'hui une base compilable avec:

- solution .NET complète
- API OTP opérationnelle
- portails d'enrôlement et d'administration
- scripts SQL initiaux
- pack de déploiement AD FS
- durcissement initial API

La solution compile actuellement sans erreur ni warning en Debug.

## Documentation utile

- [docs/architecture.md](docs/architecture.md)
- [docs/flows.md](docs/flows.md)
- [docs/mvp-plan.md](docs/mvp-plan.md)
- [docs/runbook-local.md](docs/runbook-local.md)
- [docs/adfs-integration.md](docs/adfs-integration.md)
