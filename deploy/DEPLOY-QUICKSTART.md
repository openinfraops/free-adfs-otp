# Quickstart deployment (single scripts)

This document describes the simplified deployment flow requested for farm operations.

## 1) AD FS node deployment

Script:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1`

First node (interactive + save reusable config):

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -Interactive`

Reuse same config on other AD FS nodes:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1`

Dry-run mode:

- `./deploy/adfs/Setup-AdfsOtpNode.ps1 -ConfigPath ./deploy/adfs/adfs-node.config.psd1 -DryRun`

Notes:

- The script asks for values and writes a reusable `psd1` config.
- It auto-generates `provider-config.generated.xml` from that config.
- It auto-detects AD FS `TypeName` from `FreeAdfsOtp.AdfsAdapter.dll` in the ZIP (no manual entry).
- It installs adapter from the provided AD FS adapter ZIP (no hardcoded artifacts path).
- It configures AD FS runtime in SQL direct mode (`SqlConnectionString` + `SecretMasterKeyBase64`).

## 2) Web/IIS node deployment

Script:

- `./deploy/web/Setup-WebOtpNode.ps1`

First web node (interactive + save reusable config):

- `./deploy/web/Setup-WebOtpNode.ps1 -Interactive`

Reuse same config on other web nodes:

- `./deploy/web/Setup-WebOtpNode.ps1 -ConfigPath ./deploy/web/web-node.config.psd1`

Dry-run mode:

- `./deploy/web/Setup-WebOtpNode.ps1 -ConfigPath ./deploy/web/web-node.config.psd1 -DryRun`

What it does:

- installs IIS roles/features
- deploys API, enrollment portal, admin portal from ZIP inputs
- writes appsettings including SQL connection string and API/admin keys
- creates app pools and websites with HTTPS bindings
- configures enrollment site authentication (Windows Auth enabled, Anonymous disabled by default)

## 2bis) Enrollment portal update (MAJ)

Script:

- `./deploy/web/Update-EnrollmentPortal.ps1`

Typical update with existing reusable config:

- `./deploy/web/Update-EnrollmentPortal.ps1 -ConfigPath ./deploy/web/web-node.config.psd1`

Update from another ZIP package path:

- `./deploy/web/Update-EnrollmentPortal.ps1 -ConfigPath ./deploy/web/web-node.config.psd1 -EnrollmentZipPath C:\packages\freeADFSOtp-enrollment-portal.zip`

Dry-run mode:

- `./deploy/web/Update-EnrollmentPortal.ps1 -ConfigPath ./deploy/web/web-node.config.psd1 -DryRun`

## 3) ZIP inputs expected

Use release ZIP files produced by CI/release workflow, for example:

- `freeADFSOtp-vX.Y.Z-adfs-node-package.zip`
- `freeADFSOtp-vX.Y.Z-admin-server-package.zip`

No dependency on an `artifacts` folder on target servers.
