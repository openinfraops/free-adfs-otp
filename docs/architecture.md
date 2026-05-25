# Architecture actuelle

Ce document decrit l'architecture effectivement implementee dans le code courant.

## 1) Perimetre fonctionnel implemente

- OTP TOTP pour AD FS 2019/2022
- Backend SQL Server (schema `otp.*`)
- Mode AD FS secondaire (MFA)
- Redirection vers portail d'enrollement si utilisateur non enrole
- Administration: reset methodes OTP et unlock
- Journalisation des tentatives OTP et actions admin
- Lockout parametrable via configuration

Non implemente a ce stade:

- mode primaire AD FS
- HOTP, SMS OTP, email OTP
- self-service recovery / backup codes

## 2) Composants

1. AD FS OTP Adapter (`FreeAdfsOtp.AdfsAdapter`)
- Provider AD FS `Free-ADFS-OTP`.
- UI challenge OTP dans le pipeline AD FS.
- Si non enrole: lien de redirection vers portail d'enrollement.
- Deux backends disponibles:
  - `SqlDirect` (utilise par le script de deploiement)
  - `Api` (fallback possible via config XML)

2. OTP API (`FreeAdfsOtp.Api`)
- Minimal API .NET 8.
- Endpoints: statut enrollement, validation OTP, enrollement start/verify, admin reset/unlock.
- Chiffrement des secrets OTP via AES (`SecretProtection:MasterKey`).
- Lockout et anti-replay TOTP.
- Rate limiting applicatif en memoire (par IP et/ou UPN selon endpoint).
- Services de fond:
  - purge des pending enrollments expires
  - sync cache local optionnel
  - sonde de disponibilite SQL en mode degrade

3. Enrollment Portal (`FreeAdfsOtp.EnrollmentPortal`)
- Authentification Windows obligatoire (IIS ou Negotiate).
- Derivation UPN depuis claims/session Windows.
- Formulaires start/verify d'enrollement vers API.
- Protection CSRF + controles same-origin.

4. Admin Portal (`FreeAdfsOtp.AdminPortal`)
- Authentification Windows obligatoire.
- Autorisation restreinte aux administrateurs locaux du serveur.
- Actions disponibles:
  - reset des methodes OTP
  - unlock utilisateur
- Appels API admin signes via header `X-Admin-ApiKey`.
- Protection CSRF + controles same-origin.

5. SQL Server
- Donnees OTP dans `otp.Users`, `otp.OtpMethods`, `otp.OtpSecrets`.
- Lockout dans `otp.UserLockouts`.
- Audit dans `otp.OtpAttempts` et `otp.AdminActions`.
- Enrollements en cours dans `otp.PendingEnrollments`.

## 3) Flux implementes

1. Authentification AD FS (second facteur)
- AD FS appelle l'adapter OTP.
- Adapter verifie l'enrollement (SQL direct par defaut).
- Si enrole: saisie OTP puis validation TOTP.
- Si non enrole: redirection portail d'enrollement.
- En cas de succes: emission claim `multipleauthn`.

2. Enrollement utilisateur
- Portail detecte l'utilisateur Windows et resout l'UPN.
- `POST /enrollment/start`: creation secret + QR code + etat pending.
- `POST /enrollment/verify`: verification premier code OTP puis activation methode.

3. Administration
- Portail admin appelle:
  - `POST /admin/users/{upn}/reset-methods`
  - `POST /admin/users/{upn}/unlock`
- API journalise les actions dans `otp.AdminActions`.

## 4) Securite appliquee

- Secret OTP chiffre au repos (AES-256) via `SecretProtection:MasterKey`.
- Validation TOTP avec fenetre de derive configurable.
- Protection anti-replay via `LastAcceptedTimeStep`.
- Lockout configurable (`Lockout:*`).
- Rate limiting applicatif (`RateLimiting:*`).
- Portails proteges par Windows auth + CSRF + verifications same-origin.
- Endpoints admin API proteges par API key (`AdminAuth:ApiKey`).

## 5) Disponibilite et resilience

- Mode normal: lecture/ecriture SQL.
- Option cache local API (`LocalCache:Enabled`) avec fallback de validation si SQL indisponible.
- Fenetre degradee et probing SQL controles par `SqlResilience:*`.
- Synchronisation periodique SQL -> cache local optionnelle.
