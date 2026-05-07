# AD FS Runtime Integration (Step 2)

Le fichier `AdfsOtpAdapter.Real.cs` contient l'implementation AD FS basee sur les interfaces officielles:

- `IAuthenticationAdapter`
- `IAuthenticationAdapterMetadata`
- `IAdapterPresentationForm`

## Pourquoi compilation conditionnelle

Le poste de dev ne contient pas forcement `Microsoft.IdentityServer.Web.dll` (present sur serveur AD FS).

L'implementation AD FS reelle est encapsulee sous:

- `#if ADFS_SERVER`

Ainsi, le build local reste stable. Sur serveur AD FS, activer ce symbole et ajouter la reference DLL AD FS.

## Activation sur serveur AD FS

1. Copier `Microsoft.IdentityServer.Web.dll` depuis `%windir%\ADFS`.
2. Ajouter la reference dans le projet adapter.
3. Ajouter la constante de compilation `ADFS_SERVER`.
4. Compiler, signer, deployer dans le GAC.
5. Enregistrer via `Register-AdfsAuthenticationProvider`.

## Comportement implemente

- `BeginAuthentication`:
  - lit l'UPN
  - appelle `GET /otp/enrollment-status/{upn}`
  - non enrole: affiche lien enrollment
  - enrole: affiche saisie OTP
- `TryEndAuthentication`:
  - lit `otpCode`
  - appelle `POST /otp/validate`
  - succes: retourne claim authentication method
  - echec: re-affiche formulaire

## Note

Les proprietes `IAuthenticationContext` peuvent varier selon versions AD FS/SDK; ajuster la methode `ResolveUpn` si necessaire dans votre environnement.
