# Deploiement AD FS - freeADFSOtp

Ce dossier contient les scripts PowerShell de build/deploiement du provider AD FS.

## Orchestration one-shot

Scripts ajoutes:

- `00-deploy-provider.ps1`: build + GAC + register + policy MFA
- `99-rollback-provider.ps1`: clear policy + unregister + option remove GAC
- `Setup-LocalApiService.ps1`: deploiement de l'API en service Windows local sur un noeud AD FS (sans IIS)
- `Update-AdfsConnector.ps1`: mise a jour du connecteur ADFS (GAC + re-register provider via XML)
- `Update-LocalApiService.ps1`: mise a jour de l'API locale a partir de la config existante

Fichiers de configuration environnement:

- `./deploy/adfs/environments/preprod.sample.psd1`
- `./deploy/adfs/environments/prod.sample.psd1`

Copier un fichier sample et remplacer les placeholders (`PublicKeyToken`, URLs, chemins).

Exemple preprod en simulation:

- `./deploy/adfs/00-deploy-provider.ps1 -ConfigPath ./deploy/adfs/environments/preprod.sample.psd1 -DryRun`

Exemple preprod reel:

- `./deploy/adfs/00-deploy-provider.ps1 -ConfigPath ./deploy/adfs/environments/preprod.sample.psd1 -RestartAdfsService`

Rollback simulation:

- `./deploy/adfs/99-rollback-provider.ps1 -ConfigPath ./deploy/adfs/environments/preprod.sample.psd1 -DryRun`

Rollback reel avec suppression GAC:

- `./deploy/adfs/99-rollback-provider.ps1 -ConfigPath ./deploy/adfs/environments/preprod.sample.psd1 -RestartAdfsService -RemoveFromGac -GacIdentity "FreeAdfsOtp.AdfsAdapter, Version=1.0.0.0, Culture=neutral, PublicKeyToken=PUT_TOKEN_HERE, processorArchitecture=MSIL"`

## Prerequis

- Serveur AD FS 2019/2022
- Compte admin local + droits AD FS admin
- `Microsoft.IdentityServer.Web.dll` present sur le serveur AD FS (`%windir%\\ADFS`)

## 1) Build adapter (avec runtime AD FS)

Exemple:

- `./deploy/adfs/01-build-adapter.ps1 -Configuration Release -AdfsAssemblyPath "C:\\Windows\\ADFS\\Microsoft.IdentityServer.Web.dll"`

Sortie par defaut:

- `./artifacts/adfs-adapter/FreeAdfsOtp.AdfsAdapter.dll`

## 2) Installer en GAC

Exemple:

- `./deploy/adfs/02-gac-install.ps1 -AdapterDllPath ".\\artifacts\\adfs-adapter\\FreeAdfsOtp.AdfsAdapter.dll"`

## 3) Enregistrer le provider

Le TypeName est la forme strong type complete de l'assembly signe.

Exemple:

- `./deploy/adfs/03-register-provider.ps1 -ProviderName "Free-ADFS-OTP" -TypeName "FreeAdfsOtp.AdfsAdapter.AdapterRuntime.FreeAdfsOtpAuthenticationAdapter, FreeAdfsOtp.AdfsAdapter, Version=1.0.0.0, Culture=neutral, PublicKeyToken=PUT_TOKEN_HERE, processorArchitecture=MSIL" -ConfigurationFilePath "./deploy/adfs/provider-config.sample.xml" -RestartAdfsService`

## 4) Activer MFA policy

Exemple (MFA uniquement en externe):

- `./deploy/adfs/05-configure-mfa-policy.ps1 -ProviderName "Free-ADFS-OTP" -RequireExternalOnly -ApplyGlobalRule`

## 5) Rollback

1. Vider les regles MFA:
- `./deploy/adfs/06-clear-mfa-policy.ps1 -ProviderName "Free-ADFS-OTP"`

2. Unregister provider:
- `./deploy/adfs/04-unregister-provider.ps1 -ProviderName "Free-ADFS-OTP" -RestartAdfsService`

3. Retirer du GAC:
- `gacutil /u "FreeAdfsOtp.AdfsAdapter, Version=1.0.0.0, Culture=neutral, PublicKeyToken=PUT_TOKEN_HERE, processorArchitecture=MSIL"`

## Notes importantes

- L'assembly adapter doit etre strong-name signe avant GAC + register.
- Tester d'abord sur un serveur AD FS de preproduction.
- En mode SQL direct, verifier l'acces SQL depuis tous les noeuds AD FS.
- Conserver la meme cle `SecretMasterKeyBase64` entre API et adapter AD FS.

## Deployer l'API locale sur un noeud AD FS (sans IIS)

Ce mode permet de faire tourner `FreeAdfsOtp.Api` localement sur chaque noeud AD FS via un service Windows, sans role IIS.

### Prerequis

- Package ZIP de l'API (extrait de `package-artifacts.ps1`)
- `dotnet` runtime installe sur le noeud AD FS
- Session PowerShell admin

### Exemple interactif

- `./deploy/adfs/Setup-LocalApiService.ps1 -Interactive`

### Exemple non interactif

- `./deploy/adfs/Setup-LocalApiService.ps1 -ConfigPath ./deploy/adfs/adfs-local-api.config.psd1`

### Mise a jour API locale

- `./deploy/adfs/Update-LocalApiService.ps1 -ConfigPath ./deploy/adfs/adfs-local-api.config.psd1`

### Mise a jour connecteur ADFS

- `./deploy/adfs/Update-AdfsConnector.ps1 -Interactive`
- `./deploy/adfs/Update-AdfsConnector.ps1 -ConfigPath ./deploy/adfs/adfs-connector-update.config.psd1`

Le script:

- extrait le ZIP API dans `InstallRoot`
- met a jour `appsettings.json` (SQL, MasterKey, AdminApiKey, LocalCache)
- cree/met a jour un service Windows
- configure `ASPNETCORE_URLS` sur une URL locale (ex: `http://127.0.0.1:5180`)

Puis configure l'adapter AD FS (`ApiBaseUrl`) vers cette URL locale.

## Lire les métadonnées d'installation (registre)

Les scripts d'installation/update renseignent le registre sous `HKLM:\SOFTWARE\FreeAdfsOtp`.

- Affichage lisible:
	- `./deploy/adfs/Get-FreeAdfsOtpInstallInfo.ps1`
- Sortie JSON:
	- `./deploy/adfs/Get-FreeAdfsOtpInstallInfo.ps1 -AsJson`
