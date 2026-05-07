# Integration AD FS (2019/2022)

## 1) Packaging adapter

- Compiler un adapter AD FS en .NET Framework 4.8.
- Signer l'assembly.
- Deployer DLL + dependances sur chaque serveur AD FS.
- Redemarrer le service AD FS si necessaire selon mode de deploiement.

## 2) Enregistrement provider

Exemple PowerShell (a adapter):

- Register-AdfsAuthenticationProvider -Name "freeADFSOtp" -TypeName "Company.Security.AdfsOtpAdapter, Company.Security.AdfsOtpAdapter"
- Add-AdfsAuthenticationProviderWebContent -Name "freeADFSOtp" -Locale "fr" -Identifier "signin" -FilePath "C:\adfs-otp\signin-fr.html"

Verifier:

- Get-AdfsAuthenticationProvider

## 3) Activation en secondaire (MFA)

Exemple:

- Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider "freeADFSOtp"

Puis via Access Control Policies / Authentication Policies:

- cibler les relying parties
- definir quand le facteur additionnel est exige

## 4) Activation en primaire

Selon votre politique AD FS et version, activer le provider externe en primaire (intranet/extranet) via Global Authentication Policy.

Points d'attention:

- tester intranet et extranet separement
- verifier fallback admin break-glass
- verifier compatibilite WIA/forms + provider externe

## 5) Enrollment redirection

Dans le flux adapter:

- check enrollment status (API OTP)
- si non enrole: redirection vers Enrollment Portal
- apres enrollement: reprise pipeline AD FS avec contexte de correlation

## 6) Exploitation

- Deployer en ferme AD FS complete (tous les noeuds)
- Externaliser config vers SQL Settings
- Ajouter health checks API OTP
- Supervision sur erreurs adapter + taux echec OTP

## 7) Securite

- Timeout strict adapter->API (ex 2-3s)
- Retry limite et circuit breaker
- Certificat TLS interne valide
- Journalisation correlationId pour tracer bout en bout
