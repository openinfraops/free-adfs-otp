# AD FS Adapter Skeleton

Ce projet fournit un squelette de logique pour un Authentication Adapter AD FS.

Le runtime d'integration etape 2 est dans:

- `AdapterRuntime/AdfsOtpAdapter.Real.cs`
- `AdapterRuntime/README.runtime.md`

## Important

- L'implementation finale doit cibler les interfaces AD FS officielles (namespace Microsoft.IdentityServer.Web.Authentication).
- Les signatures exactes dependent de la version AD FS et des assemblies presents sur vos serveurs.
- Ce fichier est un point de depart pour la logique metier (check enrollment, validate OTP, redirect enrollment).

## Integration cible

1. Implementer les interfaces AD FS d'authentification adaptee.
2. Dans le challenge:
   - lire UPN
   - appeler /otp/enrollment-status/{upn}
   - si non enrole: rediriger vers portail enrollment
   - sinon: afficher saisie OTP
3. A la soumission:
   - appeler /otp/validate
   - succes: return success context
   - echec: return failure context

## Durcissement

- Timeout HTTP <= 3s
- CorrelationId sur chaque appel
- Logging securise (pas de secret, pas de code OTP en clair)
