# Plan MVP

## Sprint 0 - Cadrage

- Choisir stack:
  - Adapter AD FS: .NET Framework 4.8
  - API/Portails: .NET 8
  - SQL Server: 2019+
- Definir methode OTP initiale: TOTP RFC 6238
- Definir politique lockout cible

## Sprint 1 - Donnees + OTP core

- Creer schema SQL initial
- Implementer service OTP:
  - provisioning secret
  - verification TOTP
  - anti-replay
  - lockout policy
- Exposer endpoints API internes

## Sprint 2 - Enrollment

- Portail enrollement
- QR code provisioning TOTP
- Verification code initial
- Marquage utilisateur enrole

## Sprint 3 - AD FS integration (secondary)

- Plugin AD FS adapter
- Ecran challenge OTP
- Redirection enrollment si non enrole
- Retour au pipeline AD FS

## Sprint 4 - Admin + audit

- Portail admin
- Reset methodes OTP
- Unlock utilisateur
- Consultation logs

## Sprint 5 - Hardening

- Chiffrement secret et rotation cles
- Rate limiting
- Tests charge et tests securite
- Runbook exploitation

## Criteres d'acceptation

- Auth OTP fonctionnelle sur AD FS 2019/2022 en secondary
- Redirection enrollment pour non enroles
- Lockout actif et parametrable
- Reset admin operationnel et trace
- Logs d'usage et d'echec exploitables
