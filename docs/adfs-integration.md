# Integration AD FS (2019/2022)

Ce document decrit le mode de deploiement actuellement implemente dans les scripts AD FS.

## 1) Prerequis

- Serveur AD FS 2019/2022
- Session PowerShell en mode administrateur
- ZIP adapter AD FS genere par la CI/release
- Acces SQL depuis le serveur AD FS

Compatibilite runtime adapter:

- target .NET Framework 4.5 (net45)

## 2) Provider AD FS

Nom du provider:

- fixe a `Free-ADFS-OTP`

TypeName:

- detecte automatiquement depuis `FreeAdfsOtp.AdfsAdapter.dll` par le script
- aucune saisie manuelle du TypeName n'est necessaire

## 3) Deploiement recommande (script unique)

Script:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1`

Premier noeud (interactif + fichier de config reutilisable):

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -Interactive`

Noeuds suivants (meme config):

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1`

Simulation:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1 -DryRun`

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

## 7) Flux utilisateur non enrole

- l'adapter verifie l'etat d'enrollement OTP
- si non enrole: redirection vers `EnrollmentPortalBaseUrl`
- apres enrollement OTP valide: reprise normale de l'authentification AD FS

## 8) Bonnes pratiques exploitation

- deploiement homogene sur tous les noeuds AD FS de la ferme
- supervision des echecs OTP, lockouts et erreurs provider
- verification de la connectivite SQL depuis chaque noeud
- conservation stricte de la meme `SecretMasterKeyBase64` entre API et adapter
