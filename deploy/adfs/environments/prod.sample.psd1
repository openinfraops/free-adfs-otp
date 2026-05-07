@{
    EnvironmentName = 'prod'

    ProviderName = 'freeADFSOtp'
    TypeName = 'FreeAdfsOtp.AdfsAdapter.AdapterRuntime.FreeAdfsOtpAuthenticationAdapter, FreeAdfsOtp.AdfsAdapter, Version=1.0.0.0, Culture=neutral, PublicKeyToken=PUT_TOKEN_HERE, processorArchitecture=MSIL'

    AdfsAssemblyPath = 'C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll'
    ConfigurationFilePath = '.\deploy\adfs\provider-config.sample.xml'

    DotnetPath = 'C:\Program Files\dotnet\dotnet.exe'
    GacutilPath = 'C:\Tools\gacutil.exe'

    BuildConfiguration = 'Release'
    Framework = 'net48'
    OutputPath = '.\artifacts\adfs-adapter'
    AdapterDllPath = '.\artifacts\adfs-adapter\FreeAdfsOtp.AdfsAdapter.dll'

    RequireExternalOnly = $true
    ApplyGlobalRule = $true
}
