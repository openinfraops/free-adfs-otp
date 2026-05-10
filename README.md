# freeADFSOtp

freeADFSOtp est une solution OTP pour AD FS 2019/2022+ avec backend SQL Server. Le projet vise un déploiement on-premise, avec enrôlement utilisateur, administration des méthodes OTP, audit des usages, lockout paramétrable et intégration AD FS en authentification secondaire puis primaire.

## Fonctionnalités

- OTP TOTP avec validation API ou validation SQL directe dans l'adapter AD FS
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

Par défaut, le portail d'enrôlement identifie l'utilisateur via authentification Windows intégrée (IIS/Negotiate) et n'accepte plus la saisie libre de l'UPN.

Paramètres du portail d'enrôlement:

- [src/FreeAdfsOtp.EnrollmentPortal/appsettings.json](src/FreeAdfsOtp.EnrollmentPortal/appsettings.json) > `Enrollment:IdpName`
- [src/FreeAdfsOtp.EnrollmentPortal/appsettings.json](src/FreeAdfsOtp.EnrollmentPortal/appsettings.json) > `Enrollment:AllowedWindowsDomain`
- [src/FreeAdfsOtp.EnrollmentPortal/appsettings.json](src/FreeAdfsOtp.EnrollmentPortal/appsettings.json) > `Enrollment:DefaultUpnSuffix`
- [src/FreeAdfsOtp.EnrollmentPortal/appsettings.json](src/FreeAdfsOtp.EnrollmentPortal/appsettings.json) > `Enrollment:AllowManualUpn` (desactive par defaut)

Exemple de libellé:

- `ContosoIDP:user@contoso.com`

## Sécurité implémentée

- chiffrement AES des secrets OTP côté application
- anti-replay TOTP via `LastAcceptedTimeStep`
- lockout utilisateur paramétrable
- protection minimale des endpoints admin via header `X-Admin-ApiKey`
- rate limiting par IP et par UPN sur les endpoints critiques
- nettoyage automatique des enrollments expirés
- portail d'enrôlement protégé par authentification Windows intégrée, avec résolution automatique du compte
- en-têtes de durcissement web sur le portail d'enrôlement (HSTS/CSP/X-Frame-Options/X-Content-Type-Options)

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

En mode SQL direct, l'adapter AD FS valide l'OTP sans dépendre de la disponibilité de l'API Admin/API OTP.

Mode simplifie (scripts interactifs + config reutilisable ferme):

- [deploy/DEPLOY-QUICKSTART.md](deploy/DEPLOY-QUICKSTART.md)
- [deploy/adfs/Setup-AdfsOtpNode.ps1](deploy/adfs/Setup-AdfsOtpNode.ps1)
- [deploy/web/Setup-WebOtpNode.ps1](deploy/web/Setup-WebOtpNode.ps1)

## CI GitHub

Une pipeline GitHub Actions est fournie dans [/.github/workflows/ci.yml](.github/workflows/ci.yml).

Elle exécute:

- restore NuGet
- build Release de la solution sur runner Windows
- exécution conditionnelle des tests si des projets `*Tests.csproj` sont ajoutés plus tard
- génération de ZIP de livraison
- publication des ZIP et des résultats de tests

ZIP générés:

- `freeADFSOtp-api.zip`
- `freeADFSOtp-enrollment-portal.zip`
- `freeADFSOtp-admin-portal.zip`
- `freeADFSOtp-adfs-adapter.zip`
- `freeADFSOtp-adfs-node-package.zip`
- `freeADFSOtp-admin-server-package.zip`
- `freeADFSOtp-complete.zip`

La génération locale utilise [deploy/package-artifacts.ps1](deploy/package-artifacts.ps1).

Note: la CI peut signer automatiquement l'assembly adapter si le secret `ADFS_ADAPTER_SNK_BASE64` est configuré. Le build runtime AD FS complet (constante `ADFS_SERVER`) est activable si `ADFS_WEB_DLL_BASE64` est aussi fourni.

## Release GitHub

Un workflow de release est fourni dans [/.github/workflows/release.yml](.github/workflows/release.yml).

Déclenchement:

- push d'un tag `v*` comme `v1.0.0`

Ce workflow:

- rebuild la solution en Release
- génère des ZIP versionnés, par exemple `freeADFSOtp-v1.0.0-api.zip`
- génère un bundle complet `freeADFSOtp-v1.0.0-complete.zip`
- crée automatiquement la GitHub Release et y attache tous les ZIP

## État du projet

Le dépôt contient aujourd'hui une base compilable avec:

- solution .NET complète
- API OTP opérationnelle
- portails d'enrôlement et d'administration
- scripts SQL initiaux
- pack de déploiement AD FS
- durcissement initial API

## Compatibilite .NET sur serveurs

- Serveur AD FS: l'adapter cible .NET Framework 4.7 (`net47`), donc .NET 8 n'est pas requis pour l'exécution du provider.
- Serveur web (API/portails): .NET 8 est requis pour héberger les applications ASP.NET Core.

La solution compile actuellement sans erreur ni warning en Debug.

## Documentation utile

- [docs/architecture.md](docs/architecture.md)
- [docs/flows.md](docs/flows.md)
- [docs/mvp-plan.md](docs/mvp-plan.md)
- [docs/runbook-local.md](docs/runbook-local.md)
- [docs/adfs-integration.md](docs/adfs-integration.md)
