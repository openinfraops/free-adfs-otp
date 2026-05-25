# Integration AD FS (2019/2022)

Ce document decrit le mode de deploiement actuellement implemente dans les scripts AD FS.

## 1) Prerequis

- Serveur AD FS 2019/2022
- Session PowerShell en mode administrateur
- ZIP adapter AD FS genere par la CI/release
- Acces SQL depuis le serveur AD FS

Composants utilises pendant le setup:

- script `deploy/adfs/Setup-AdfsOtpNode.ps1`
- ZIP `*-adfs-node-package.zip` (ou ZIP adapter contenant `FreeAdfsOtp.AdfsAdapter.dll`)
- cmdlets AD FS (`Register-AdfsAuthenticationProvider`, `Set-AdfsGlobalAuthenticationPolicy`, etc.)

Compatibilite runtime adapter:

- target .NET Framework 4.7 (net47)

## 2) Provider AD FS

Nom du provider:

- fixe a `Free-ADFS-OTP`

TypeName:

- detecte automatiquement depuis `FreeAdfsOtp.AdfsAdapter.dll` par le script
- aucune saisie manuelle du TypeName n'est necessaire

Backend runtime configure par le script:

- XML genere avec `<Mode>SqlDirect</Mode>`
- validation OTP effectuee localement via SQL depuis le serveur AD FS
- mode `Api` reste supporte par l'adapter, mais n'est pas le mode par defaut du script

## 3) Deploiement recommande (script unique)

Script:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1`

Premier noeud (interactif + fichier de config reutilisable):

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -Interactive`

Noeuds suivants (meme config):

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1`

Simulation:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1 -DryRun`

Options utiles:

- `-SkipPolicy`: n'applique pas les regles MFA AD FS globales
- `-Interactive`: regenere le fichier de config de noeud

## 4) Informations demandees en interactif

- chemin du ZIP adapter
- SQL Server (nom serveur/instance ou serveur,port)
- base SQL (defaut: `FreeAdfsOtp`)
- mode d'auth SQL:
	- integree
	- ou login/mot de passe
- cle `SecretMasterKeyBase64` (identique a l'API)
- URL du portail d'enrollement
- options de policy AD FS (externe uniquement, application regle globale, etc.)

Sorties generees par le script:

- fichier de config noeud reutilisable (`adfs-node.config.psd1`)
- config provider XML (`provider-config.generated.xml`)
- metadonnees d'installation ecrites en registre (`HKLM:\SOFTWARE\FreeAdfsOtp\AdfsConnector`)

## 5) Installation GAC

Le deploiement utilise la methode .NET:

- `System.EnterpriseServices.Internal.Publish.GacInstall(...)`

Le workflow ne depend plus de `gacutil.exe`.

## 6) MFA policy

Le script peut automatiquement:

- enregistrer le provider `Free-ADFS-OTP`
- l'ajouter a `AdditionalAuthenticationProvider`
- appliquer la regle AD FS globale MFA

Externe uniquement (recommande):

- MFA imposee quand `insidecorporatenetwork == false`

Si `RequireExternalOnly = false`:

- la regle globale applique `multipleauthn` sans condition `insidecorporatenetwork`

## 7) Flux utilisateur non enrole

- l'adapter verifie l'etat d'enrollement OTP
- si non enrole: redirection vers `EnrollmentPortalBaseUrl`
- apres enrollement OTP valide: reprise normale de l'authentification AD FS

Claim emis en cas de succes OTP:

- `http://schemas.microsoft.com/claims/multipleauthn`

## 8) Bonnes pratiques exploitation

- deploiement homogene sur tous les noeuds AD FS de la ferme
- supervision des echecs OTP, lockouts et erreurs provider
- verification de la connectivite SQL depuis chaque noeud
- conservation stricte de la meme `SecretMasterKeyBase64` entre API et adapter

Recommandations supplementaires:

- conserver le meme `adfs-node.config.psd1` sur tous les noeuds (hors chemins locaux)
- utiliser `-DryRun` avant chaque deploiement en production
- tester explicitement reset/unregister (`04-unregister-provider.ps1`) sur preprod
