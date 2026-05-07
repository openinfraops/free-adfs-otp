# Architecture cible

## 1) Exigences fonctionnelles

- OTP pour AD FS 2019/2022
- Backend SQL Server
- Mode primaire ou secondaire
- Si utilisateur non enrole: redirection vers interface d'enrollement
- Admin: reset methodes OTP utilisateur
- Logs: succes, echecs, tentative invalide, lockout
- Lockout parametrable (seuil, fenetre, duree)

## 2) Architecture logique

1. AD FS OTP Adapter
- Plugin AD FS.
- Verifie et orchestre le challenge OTP.
- Interroge API OTP (ou acces direct SQL si choix on-prem strict).

2. OTP Core API
- Service metier OTP.
- Genere/valide TOTP/HOTP.
- Gere l'etat enrollement.
- Applique lockout policy.
- Expose endpoints admin (reset methodes, unlock).
- Protege les endpoints admin via secret d'administration (API key) minimum.

3. Enrollment Portal
- Activation des methodes OTP (TOTP app, email OTP, SMS OTP selon choix).
- Verification initiale OTP pour finaliser enrollement.
- Provisioning via QR code TOTP.
- Libelle compte telephone: `IDP:Compte` (ex: `ContosoIDP:user@contoso.com`).

4. Admin Portal
- Recherche utilisateur.
- Reset methodes OTP.
- Deblocage lockout.
- Visualisation logs et echec OTP.

5. SQL Server
- Stockage methodes OTP, secrets chiffres, historiques, lockout, audit.
- Stockage des enrollments pending (ephemeres) pour support multi-instance API.

## 3) Flux d'authentification

### A. Mode secondaire (recommande pour phase 1)

1. Utilisateur s'authentifie en primaire AD/Forms.
2. AD FS appelle OTP Adapter en second facteur.
3. Adapter verifie enrollement:
- enrole -> challenge OTP
- non enrole -> redirection enrollment portal
4. Apres enrollement, reprise du flux AD FS.
5. Si OTP valide -> emission token.
6. Si OTP invalide -> compteur echec + lockout si seuil atteint.

### B. Mode primaire (phase 2)

1. AD FS invoque provider externe comme methode primaire.
2. Provider effectue identification (UPN/login) + OTP.
3. Si non enrole -> enrollment flow controle.
4. Si succes -> claims de base renvoyees a AD FS.

Note: valider selon votre politique AD FS si le provider externe est autorise en primaire sur tous les contextes (intranet/extranet).

## 4) Securite

- Secret OTP chiffre au repos (AES-256), cle stockee hors base (DPAPI machine store, HSM, Azure Key Vault, ou equivalent).
- Rotation des cles de chiffrement supportee.
- Hash + salt des codes de secours (recovery codes).
- Horodatage UTC partout.
- Anti-replay: fenetre TOTP stricte (+/- 1 step max) et prevention reutilisation de code deja accepte dans la fenetre.
- Rate limiting par utilisateur + IP + User-Agent.
- Journalisation immutable orientee audit.
- Nettoyage automatique des enrollments pending expires.

## 5) Lockout parametrable

Parametres recommandables:

- maxFailedAttempts (ex: 5)
- failedWindowMinutes (ex: 10)
- lockoutMinutes (ex: 15)
- permanentAfterConsecutiveLockouts (optionnel)

Politique:

- Si nombre d'echecs dans la fenetre >= maxFailedAttempts, lockout actif jusqu'a lockedUntilUtc.
- Les tentatives pendant lockout sont loggees avec reason=LOCKED.
- Admin peut unlock manuel.

## 6) Administration

Actions minimales:

- Reset OTP methods utilisateur (desactivation + suppression secrets)
- Force re-enrollment
- Unlock user
- Consultation logs OTP

Traçabilite admin:

- Qui a fait l'action (adminUpn)
- Quand (utc)
- Sur quel utilisateur
- Pourquoi (reason obligatoire)

## 7) Disponibilite et exploitation

- SQL HA (Always On / cluster).
- API OTP stateless, scalable horizontalement.
- Adapter AD FS resilient: timeout court vers API + fallback explicite.
- Supervision:
  - taux succes OTP
  - taux echec OTP
  - lockout actifs
  - latence validation OTP

## 8) Strategie d'implementation

- Phase 1: Secondary auth adapter + enrollment + SQL + lockout + logs + admin reset.
- Phase 2: Mode primaire + hardening avance + reporting.
- Phase 3: Experience utilisateur (self-service recovery, backup codes, facteur alternatif).
