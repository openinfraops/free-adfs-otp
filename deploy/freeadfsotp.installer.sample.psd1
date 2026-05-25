@{
    AdfsConfigPath = 'C:\Program Files\FreeAdfsOtp\config\adfs-node.config.psd1'
    LocalApiConfigPath = 'C:\Program Files\FreeAdfsOtp\config\adfs-local-api.config.psd1'
    WebConfigPath = 'C:\Program Files\FreeAdfsOtp\config\web-node.config.psd1'

    SqlServer = 'localhost'
    SqlDatabase = 'FreeAdfsOtp'
    UseIntegratedSecurity = $true
    SqlUser = ''
    SqlPassword = ''
    SqlScriptsRoot = '.\sql'
}
