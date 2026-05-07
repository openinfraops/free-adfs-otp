@{
    EnvironmentName = 'preprod'

    ProviderName = 'freeADFSOtp'
    TypeName = 'FreeAdfsOtp.AdfsAdapter.AdapterRuntime.FreeAdfsOtpAuthenticationAdapter, FreeAdfsOtp.AdfsAdapter, Version=1.0.0.0, Culture=neutral, PublicKeyToken=PUT_TOKEN_HERE, processorArchitecture=MSIL'

    # AD FS runtime assembly location on server
    AdfsAssemblyPath = 'C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll'

    # Provider XML config consumed by Register-AdfsAuthenticationProvider
    ConfigurationFilePath = '.\deploy\adfs\provider-config.sample.xml'

    # Build and deployment tool paths
    DotnetPath = 'C:\Program Files\dotnet\dotnet.exe'
    GacutilPath = 'C:\Tools\gacutil.exe'

    # Build output
    BuildConfiguration = 'Release'
    Framework = 'net48'
    OutputPath = '.\artifacts\adfs-adapter'

    # Final built DLL path (usually inside OutputPath)
    AdapterDllPath = '.\artifacts\adfs-adapter\FreeAdfsOtp.AdfsAdapter.dll'

    # MFA policy behavior
    RequireExternalOnly = $true
    ApplyGlobalRule = $true
}
