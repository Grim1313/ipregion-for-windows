#requires -Version 7.4

<#
.SYNOPSIS
Checks the apparent country of the current public IP across GeoIP providers,
popular services, and CDN endpoints.

.DESCRIPTION
Native Windows implementation of ipregion. It uses PowerShell and .NET only;
curl, jq, WSL, Git Bash, and third-party runtime modules are not required.

.PARAMETER Group
Selects All, Primary/GeoIP, Custom, or Cdn checks.

.PARAMETER IPv4
Runs only IPv4 checks. Alias: -4.

.PARAMETER IPv6
Runs only IPv6 checks. Alias: -6.

.PARAMETER Proxy
Uses an HTTP or SOCKS proxy. A value without a scheme is treated as SOCKS5.

.PARAMETER Interface
Binds outgoing sockets to an address assigned to this Windows interface alias.

.PARAMETER Json
Writes stable JSON instead of the human-readable report.

.PARAMETER ThrottleLimit
Limits concurrent independent service checks. Use 1 for sequential execution.

.PARAMETER NoProgress
Disables the interactive progress indicator.

.EXAMPLE
pwsh ./ipregion.ps1 -IPv4

.EXAMPLE
pwsh ./ipregion.ps1 -Group Primary -Proxy 127.0.0.1:1080 -Json
#>

param(
    [Alias('h')]
    [switch]$Help,

    [Alias('g')]
    [ValidateSet('All', 'Primary', 'GeoIP', 'Custom', 'Cdn')]
    [string]$Group = 'All',

    [Alias('t')]
    [ValidateRange(1, 120)]
    [int]$Timeout = 5,

    [ValidateRange(1, 16)]
    [int]$ThrottleLimit = 6,

    [Alias('4')]
    [switch]$IPv4,

    [Alias('6')]
    [switch]$IPv6,

    [Alias('p')]
    [string]$Proxy,

    [Alias('i')]
    [string]$Interface,

    [Alias('j')]
    [switch]$Json,

    [Alias('v')]
    [switch]$VerboseOutput,

    [Alias('d')]
    [switch]$DebugLog,

    [switch]$NoColor,

    [switch]$NoProgress,

    [switch]$IncludeIntrusiveChecks
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ScriptVersion = '0.1.0'
$script:ScriptUrl = 'https://github.com/Grim1313/ipregion-for-windows'
$script:ScriptPath = $PSCommandPath
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0'
$script:StatusDenied = 'Denied'
$script:StatusRateLimit = 'Rate-limit'
$script:StatusServerError = 'Server error'
$script:StatusNotAvailable = 'N/A'
$script:DebugPath = Join-Path $PWD ("ipregion_debug_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
$script:Clients = @{}
$script:Metadata = @{}

$script:Secrets = @{
    SpotifyApiKey = '142b583129b2df829de3656f9eb484e6'
    SpotifyClientId = '9a8d2f0ce77a4e248bb71fefcb557637'
    NetflixApiKey = 'YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm'
    TwitchClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko'
    ChatGptStatsigApiKey = 'client-zUdXdSTygXJdzoE0sWTkP8GKTVsUMF2IRM7ShVO2JAG'
    RedditBasicAccessToken = 'b2hYcG9xclpZdWIxa2c6'
    YouTubeSocsCookie = 'CAISNQgDEitib3FfaWRlbnRpdHlmcm9udGVuZHVpc2VydmVyXzIwMjUwNzMwLjA1X3AwGgJlbiACGgYIgPC_xAY'
    DisneyPlusApiKey = 'ZGlzbmV5JmFuZHJvaWQmMS4wLjA.bkeb0m230uUhv8qrAXuNu39tbE_mD5EEhM_NAcohjyA'
}

$script:DisneyPlusBody = @{
    query = "`n mutation registerDevice(`$registerDevice: RegisterDeviceInput!) { registerDevice(registerDevice: `$registerDevice) { __typename } }"
    variables = @{
        registerDevice = @{
            applicationRuntime = 'android'
            attributes = @{ operatingSystem = 'Android'; operatingSystemVersion = '13' }
            deviceFamily = 'android'
            deviceLanguage = 'en'
            deviceProfile = 'phone'
            devicePlatformId = 'android'
        }
    }
    operationName = 'registerDevice'
} | ConvertTo-Json -Depth 8 -Compress

$script:PrimaryServices = @(
    @{ Key = 'MAXMIND'; Name = 'maxmind.com'; Url = 'https://geoip.maxmind.com/geoip/v2.1/city/me'; Path = 'country.iso_code'; Headers = @{ Referer = 'https://www.maxmind.com' } }
    @{ Key = 'RIPE'; Name = 'rdap.db.ripe.net'; Url = 'https://rdap.db.ripe.net/ip/{ip}'; Path = 'country' }
    @{ Key = 'IPINFO_IO'; Name = 'ipinfo.io'; Url = 'https://ipinfo.io/widget/demo/{ip}'; Path = 'data.country'; IPv6OverIPv4 = $true }
    @{ Key = 'CLOUDFLARE'; Name = 'cloudflare.com'; Url = 'https://speed.cloudflare.com/meta'; Path = 'country'; Headers = @{ Referer = 'https://speed.cloudflare.com' } }
    @{ Key = 'IPREGISTRY'; Name = 'ipregistry.co'; Url = 'https://api.ipregistry.co/{ip}?hostname=true&key=sb69ksjcajfs4c'; Path = 'location.country.code'; Headers = @{ Origin = 'https://ipregistry.co' } }
    @{ Key = 'IPAPI_CO'; Name = 'ipapi.co'; Url = 'https://ipapi.co/{ip}/json'; Path = 'country' }
    @{ Key = 'IFCONFIG_CO'; Name = 'ifconfig.co'; Url = 'https://ifconfig.co/country-iso?ip={ip}'; Plain = $true }
    @{ Key = 'IP2LOCATION_IO'; Name = 'ip2location.io'; Url = 'https://api.ip2location.io/?ip={ip}'; Path = 'country_code' }
    @{ Key = 'IPLOCATION_COM'; Name = 'iplocation.com'; Custom = $true; IPv6OverIPv4 = $true }
    @{ Key = 'COUNTRY_IS'; Name = 'country.is'; Url = 'https://api.country.is/{ip}'; Path = 'country' }
    @{ Key = 'GEOAPIFY_COM'; Name = 'geoapify.com'; Url = 'https://api.geoapify.com/v1/ipinfo?ip={ip}&apiKey=b8568cb9afc64fad861a69edbddb2658'; Path = 'country.iso_code' }
    @{ Key = 'GEOJS_IO'; Name = 'geojs.io'; Url = 'https://get.geojs.io/v1/ip/country.json?ip={ip}'; Path = '0.country' }
    @{ Key = 'IPAPI_IS'; Name = 'ipapi.is'; Url = 'https://api.ipapi.is/?q={ip}'; Path = 'location.country_code'; IPv6OverIPv4 = $true }
    @{ Key = 'IPBASE_COM'; Name = 'ipbase.com'; Url = 'https://api.ipbase.com/v2/info?ip={ip}'; Path = 'data.location.country.alpha2' }
    @{ Key = 'IPQUERY_IO'; Name = 'ipquery.io'; Url = 'https://api.ipquery.io/{ip}'; Path = 'location.country_code' }
    @{ Key = 'IPWHO_IS'; Name = 'ipwho.is'; Url = 'https://ipwho.is/{ip}'; Path = 'country_code'; IPv6OverIPv4 = $true }
    @{ Key = 'IPAPI_COM'; Name = 'ip-api.com'; Url = 'https://demo.ip-api.com/json/{ip}?fields=countryCode'; Path = 'countryCode'; Headers = @{ Origin = 'https://ip-api.com' }; IPv6OverIPv4 = $true }
    @{ Key = '2IP'; Name = '2ip.io'; Url = 'https://api.2ip.io/?ip={ip}'; Path = 'code' }
)

$script:CustomServices = @(
    @{ Key = 'GOOGLE'; Name = 'Google' }
    @{ Key = 'YOUTUBE'; Name = 'YouTube' }
    @{ Key = 'YOUTUBE_MUSIC'; Name = 'YouTube Music' }
    @{ Key = 'TWITCH'; Name = 'Twitch' }
    @{ Key = 'CHATGPT'; Name = 'ChatGPT' }
    @{ Key = 'NETFLIX'; Name = 'Netflix' }
    @{ Key = 'SPOTIFY'; Name = 'Spotify' }
    @{ Key = 'DEEZER'; Name = 'Deezer' }
    @{ Key = 'REDDIT'; Name = 'Reddit' }
    @{ Key = 'DISNEY_PLUS'; Name = 'Disney+' }
    @{ Key = 'GEMINI_SUPPORTED'; Name = 'Gemini Supported' }
    @{ Key = 'REDDIT_GUEST_ACCESS'; Name = 'Reddit (Guest Access)' }
    @{ Key = 'YOUTUBE_PREMIUM'; Name = 'YouTube Premium' }
    @{ Key = 'GOOGLE_SEARCH_CAPTCHA'; Name = 'Google Search Captcha'; Intrusive = $true }
    @{ Key = 'SPOTIFY_SIGNUP'; Name = 'Spotify Signup' }
    @{ Key = 'DISNEY_PLUS_ACCESS'; Name = 'Disney+ Access' }
    @{ Key = 'AMAZON_PRIME'; Name = 'Amazon Prime' }
    @{ Key = 'APPLE'; Name = 'Apple' }
    @{ Key = 'STEAM'; Name = 'Steam' }
    @{ Key = 'TIKTOK'; Name = 'TikTok' }
    @{ Key = 'OOKLA_SPEEDTEST'; Name = 'Ookla Speedtest' }
    @{ Key = 'JETBRAINS'; Name = 'JetBrains' }
    @{ Key = 'PLAYSTATION'; Name = 'PlayStation' }
    @{ Key = 'MICROSOFT'; Name = 'Microsoft' }
    @{ Key = 'BING'; Name = 'Bing' }
)

$script:CdnServices = @(
    @{ Key = 'CLOUDFLARE_CDN'; Name = 'Cloudflare CDN' }
    @{ Key = 'YOUTUBE_CDN'; Name = 'YouTube CDN' }
    @{ Key = 'NETFLIX_CDN'; Name = 'Netflix CDN' }
)

function Write-IpLog {
    param([string]$Level, [string]$Message)

    $line = '{0:o} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), $Message
    if ($DebugLog) {
        Add-Content -LiteralPath $script:DebugPath -Value $line -Encoding utf8NoBOM
    }
    if ($VerboseOutput -or $VerbosePreference -eq 'Continue') {
        [Console]::Error.WriteLine($line)
    }
}

function Write-IpProgress {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Status,
        [ValidateRange(0, 100)][int]$PercentComplete,
        [switch]$Completed
    )

    if ($NoProgress -or $Json -or [Console]::IsOutputRedirected) {
        return
    }
    if ($Completed) {
        Write-Progress -Id 1 -Activity $Activity -Status $Status -Completed
        return
    }
    Write-Progress -Id 1 -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function Initialize-TransportType {
    if ('IpRegion.TransportFactory' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace IpRegion
{
    public static class TransportFactory
    {
        public static SocketsHttpHandler Create(AddressFamily family, string localAddress, string proxy)
        {
            var handler = new SocketsHttpHandler
            {
                AllowAutoRedirect = true,
                AutomaticDecompression = DecompressionMethods.All,
                ConnectTimeout = TimeSpan.FromSeconds(10),
                MaxAutomaticRedirections = 8,
                MaxConnectionsPerServer = 8,
                PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
                PooledConnectionLifetime = TimeSpan.FromMinutes(5),
                UseCookies = false
            };

            if (!string.IsNullOrWhiteSpace(proxy))
            {
                handler.Proxy = new WebProxy(proxy);
                handler.UseProxy = true;
            }

            IPAddress bindAddress = null;
            if (!string.IsNullOrWhiteSpace(localAddress))
                bindAddress = IPAddress.Parse(localAddress);

            handler.ConnectCallback = async (context, cancellationToken) =>
            {
                var socket = new Socket(family, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    socket.NoDelay = true;
                    if (bindAddress != null)
                        socket.Bind(new IPEndPoint(bindAddress, 0));
                    await socket.ConnectAsync(context.DnsEndPoint, cancellationToken).ConfigureAwait(false);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            };

            return handler;
        }
    }
}
'@
}

function Resolve-InterfaceAddress {
    param([ValidateSet(4, 6)][int]$IpVersion)

    if ([string]::IsNullOrWhiteSpace($Interface)) {
        return $null
    }

    $family = if ($IpVersion -eq 4) { 'IPv4' } else { 'IPv6' }
    $addresses = @(Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily $family -AddressState Preferred -ErrorAction Stop |
        Where-Object { $_.IPAddress -notmatch '^(127\.|::1$|fe80:)' })
    if ($addresses.Count -eq 0) {
        throw "Interface '$Interface' has no usable $family address."
    }
    return $addresses[0].IPAddress
}

function Initialize-IpClient {
    param([ValidateSet(4, 6)][int]$IpVersion)

    Initialize-TransportType
    $family = if ($IpVersion -eq 4) {
        [System.Net.Sockets.AddressFamily]::InterNetwork
    } else {
        [System.Net.Sockets.AddressFamily]::InterNetworkV6
    }
    $localAddress = Resolve-InterfaceAddress -IpVersion $IpVersion
    $proxyUri = $Proxy
    if (-not [string]::IsNullOrWhiteSpace($proxyUri) -and $proxyUri -notmatch '^[a-z][a-z0-9+.-]*://') {
        $proxyUri = "socks5://$proxyUri"
    }
    $handler = [IpRegion.TransportFactory]::Create($family, $localAddress, $proxyUri)
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    return $client
}

function Get-IpClient {
    param([ValidateSet(4, 6)][int]$IpVersion)

    if (-not $script:Clients.ContainsKey($IpVersion)) {
        $script:Clients[$IpVersion] = Initialize-IpClient -IpVersion $IpVersion
    }
    return $script:Clients[$IpVersion]
}

function Get-HttpStatusValue {
    param([int]$StatusCode)

    if ($StatusCode -eq 403) { return $script:StatusDenied }
    if ($StatusCode -eq 429) { return $script:StatusRateLimit }
    if ($StatusCode -ge 500) { return $script:StatusServerError }
    if ($StatusCode -ge 400) { return $script:StatusNotAvailable }
    return $null
}

function Invoke-IpRequest {
    param(
        [ValidateSet(4, 6)][int]$IpVersion,
        [ValidateSet('GET', 'POST', 'HEAD')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][string]$Body,
        [string]$ContentType = 'application/json',
        [int]$RetryCount = 1
    )

    $client = Get-IpClient -IpVersion $IpVersion
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($Timeout))
        try {
            [void]$request.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent)
            foreach ($header in $Headers.GetEnumerator()) {
                [void]$request.Headers.TryAddWithoutValidation([string]$header.Key, [string]$header.Value)
            }
            if ($null -ne $Body) {
                $request.Content = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, $ContentType)
            }

            Write-IpLog -Level Debug -Message "$Method $Uri over IPv$IpVersion (attempt $($attempt + 1))"
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $cts.Token).GetAwaiter().GetResult()
            try {
                $statusCode = [int]$response.StatusCode
                $responseBody = if ($Method -eq 'HEAD') { '' } else { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
                $allHeaders = [System.Text.StringBuilder]::new()
                foreach ($header in $response.Headers) {
                    [void]$allHeaders.AppendLine(('{0}: {1}' -f $header.Key, ($header.Value -join ', ')))
                }
                foreach ($header in $response.Content.Headers) {
                    [void]$allHeaders.AppendLine(('{0}: {1}' -f $header.Key, ($header.Value -join ', ')))
                }
                $statusValue = Get-HttpStatusValue -StatusCode $statusCode
                return [pscustomobject]@{
                    Success = $statusCode -lt 400
                    StatusCode = $statusCode
                    StatusValue = $statusValue
                    Body = $responseBody
                    Headers = $allHeaders.ToString()
                    Error = $null
                }
            } finally {
                $response.Dispose()
            }
        } catch [System.OperationCanceledException] {
            Write-IpLog -Level Warning -Message "Timeout for $Uri over IPv$IpVersion"
            if ($attempt -eq $RetryCount) {
                return [pscustomobject]@{ Success = $false; StatusCode = 0; StatusValue = $script:StatusNotAvailable; Body = ''; Headers = ''; Error = 'Timeout' }
            }
        } catch {
            Write-IpLog -Level Warning -Message "Request failed for $Uri over IPv${IpVersion}: $($_.Exception.Message)"
            if ($attempt -eq $RetryCount) {
                return [pscustomobject]@{ Success = $false; StatusCode = 0; StatusValue = $script:StatusNotAvailable; Body = ''; Headers = ''; Error = $_.Exception.Message }
            }
        } finally {
            $cts.Dispose()
            $request.Dispose()
        }
    }
}

function ConvertFrom-JsonSafe {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return $Text | ConvertFrom-Json -Depth 32 -NoEnumerate -ErrorAction Stop } catch { return $null }
}

function Get-JsonPathValue {
    param($Object, [string]$Path)

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($part -match '^\d+$') {
            $index = [int]$part
            if ($current -isnot [System.Collections.IList] -or $index -ge $current.Count) { return $null }
            $current = $current[$index]
        } else {
            $property = $current.PSObject.Properties[$part]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
    }
    return $current
}

function ConvertTo-CountryCode {
    param($Value)

    if ($null -eq $Value) { return $script:StatusNotAvailable }
    $text = ([string]$Value).Trim().ToUpperInvariant()
    if ($text -match '^[A-Z]{2}$') { return $text }
    if ($text -in @($script:StatusDenied.ToUpperInvariant(), $script:StatusRateLimit.ToUpperInvariant(), $script:StatusServerError.ToUpperInvariant(), $script:StatusNotAvailable.ToUpperInvariant())) {
        switch ($text) {
            'DENIED' { return $script:StatusDenied }
            'RATE-LIMIT' { return $script:StatusRateLimit }
            'SERVER ERROR' { return $script:StatusServerError }
            default { return $script:StatusNotAvailable }
        }
    }
    return $script:StatusNotAvailable
}

function Get-ResponseValue {
    param($Response, [string]$Path, [switch]$Plain)

    if (-not $Response.Success) { return $Response.StatusValue }
    if ($Plain) { return ConvertTo-CountryCode -Value $Response.Body }
    $object = ConvertFrom-JsonSafe -Text $Response.Body
    if ($null -eq $object) { return $script:StatusNotAvailable }
    return ConvertTo-CountryCode -Value (Get-JsonPathValue -Object $object -Path $Path)
}

function Test-AddressFamily {
    param([string]$Address, [ValidateSet(4, 6)][int]$IpVersion)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsed)) { return $false }
    if ($IpVersion -eq 4) { return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
}

function Find-ExternalAddress {
    param([ValidateSet(4, 6)][int]$IpVersion)

    $services = @('https://api64.ipify.org', 'https://ident.me', 'https://ifconfig.me/ip')
    $first = $null
    $failures = 0
    foreach ($uri in $services) {
        $response = Invoke-IpRequest -IpVersion $IpVersion -Uri $uri -RetryCount 0
        $candidate = $response.Body.Trim()
        if (-not $response.Success -or -not (Test-AddressFamily -Address $candidate -IpVersion $IpVersion)) {
            $failures++
            if ($failures -ge 2) { break }
            continue
        }
        if ($null -eq $first) {
            $first = $candidate
            continue
        }
        if ($candidate -eq $first) {
            return $candidate
        }
    }
    return $first
}

function Get-NetworkInfo {
    param([ValidateSet(4, 6)][int]$IpVersion)

    if ($script:Metadata.ContainsKey($IpVersion)) { return $script:Metadata[$IpVersion] }
    $response = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://geoip.maxmind.com/geoip/v2.1/city/me' -Headers @{ Referer = 'https://www.maxmind.com' }
    $jsonObject = ConvertFrom-JsonSafe -Text $response.Body
    $metadata = [pscustomobject]@{
        Country = if ($jsonObject) { ConvertTo-CountryCode (Get-JsonPathValue $jsonObject 'country.iso_code') } else { $response.StatusValue }
        RegisteredCountry = if ($jsonObject) { [string](Get-JsonPathValue $jsonObject 'registered_country.names.en') } else { '' }
        Asn = if ($jsonObject) { Get-JsonPathValue $jsonObject 'traits.autonomous_system_number' } else { $null }
        AsnName = if ($jsonObject) { [string](Get-JsonPathValue $jsonObject 'traits.autonomous_system_organization') } else { '' }
    }
    $script:Metadata[$IpVersion] = $metadata
    return $metadata
}

function Invoke-PrimaryLookup {
    param([hashtable]$Service, [ValidateSet(4, 6)][int]$AddressVersion, [string]$Address)

    if ($Service.Key -eq 'MAXMIND') {
        return (Get-NetworkInfo -IpVersion $AddressVersion).Country
    }
    $usesIpv4Transport = $Service.ContainsKey('IPv6OverIPv4') -and [bool]$Service.IPv6OverIPv4
    $isCustom = $Service.ContainsKey('Custom') -and [bool]$Service.Custom
    $transportVersion = if ($AddressVersion -eq 6 -and $usesIpv4Transport) { 4 } else { $AddressVersion }
    if ($isCustom) {
        $body = 'ip={0}' -f [Uri]::EscapeDataString($Address)
        $response = Invoke-IpRequest -IpVersion $transportVersion -Method POST -Uri 'https://iplocation.com' -Body $body -ContentType 'application/x-www-form-urlencoded'
        return Get-ResponseValue -Response $response -Path 'country_code'
    }
    $uri = $Service.Url.Replace('{ip}', [Uri]::EscapeDataString($Address))
    $headers = if ($Service.ContainsKey('Headers')) { $Service.Headers } else { @{} }
    $response = Invoke-IpRequest -IpVersion $transportVersion -Uri $uri -Headers $headers
    $isPlain = $Service.ContainsKey('Plain') -and [bool]$Service.Plain
    $path = if ($Service.ContainsKey('Path')) { [string]$Service.Path } else { '' }
    return Get-ResponseValue -Response $response -Path $path -Plain:$isPlain
}

function Get-BooleanAvailability {
    param([bool]$Available)
    if ($Available) { return 'Yes' }
    return 'No'
}

function Invoke-DisneyRequest {
    param([ValidateSet(4, 6)][int]$IpVersion)
    return Invoke-IpRequest -IpVersion $IpVersion -Method POST -Uri 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql' -Headers @{ Authorization = "Bearer $($script:Secrets.DisneyPlusApiKey)" } -Body $script:DisneyPlusBody
}

function Get-IataCountry {
    param([string]$Iata)
    if ($Iata -notmatch '^[A-Za-z]{3}$') { return $script:StatusNotAvailable }
    $body = 'iata={0}' -f $Iata.ToUpperInvariant()
    $response = Invoke-IpRequest -IpVersion 4 -Method POST -Uri 'https://www.air-port-codes.com/api/v1/single' -Headers @{ 'APC-Auth' = '96dc04b3fb'; Referer = 'https://www.air-port-codes.com/' } -Body $body -ContentType 'application/x-www-form-urlencoded'
    $country = Get-ResponseValue -Response $response -Path 'airport.country.iso'
    if ($country -match '^[A-Z]{2}$') { return "$country ($($Iata.ToUpperInvariant()))" }
    return $country
}

function Invoke-CustomLookup {
    param([string]$Key, [ValidateSet(4, 6)][int]$IpVersion)

    switch ($Key) {
        'GOOGLE' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://accounts.google.com/v3/signin/identifier?flowName=GlifSetupAndroid'
            if ($r.Success -and $r.Body -match 'name="region"\s+value="([^"]+)"') { return ConvertTo-CountryCode $Matches[1] }
            return $r.StatusValue
        }
        'YOUTUBE' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.youtube.com/sw.js_data'
            if (-not $r.Success) { return $r.StatusValue }
            $payload = ($r.Body -split "`n" | Select-Object -Skip 2) -join "`n"
            $o = ConvertFrom-JsonSafe $payload
            return ConvertTo-CountryCode (Get-JsonPathValue $o '0.2.0.0.1')
        }
        'YOUTUBE_MUSIC' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://music.youtube.com/' -Headers @{ Cookie = "SOCS=$($script:Secrets.YouTubeSocsCookie)"; 'Accept-Language' = 'en-US,en;q=0.9' }
            if (-not $r.Success) { return $r.StatusValue }
            return Get-BooleanAvailability ($r.Body -notmatch '(?i)YouTube Music is not available in your area')
        }
        'TWITCH' {
            $body = '[{"operationName":"VerifyEmail_CurrentUser","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f9e7dcdf7e99c314c82d8f7f725fab5f99d1df3d7359b53c9ae122deec590198"}}}]'
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method POST -Uri 'https://gql.twitch.tv/gql' -Headers @{ 'Client-Id' = $script:Secrets.TwitchClientId } -Body $body
            return Get-ResponseValue $r '0.data.requestInfo.countryCode'
        }
        'CHATGPT' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method POST -Uri 'https://ab.chatgpt.com/v1/initialize' -Headers @{ 'Statsig-Api-Key' = $script:Secrets.ChatGptStatsigApiKey }
            return Get-ResponseValue $r 'derived_fields.country'
        }
        'NETFLIX' {
            $uri = "https://api.fast.com/netflix/speedtest/v2?https=true&token=$($script:Secrets.NetflixApiKey)&urlCount=1"
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri $uri
            return Get-ResponseValue $r 'client.location.country'
        }
        { $_ -in @('SPOTIFY', 'SPOTIFY_SIGNUP') } {
            $uri = "https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=$($script:Secrets.SpotifyApiKey)"
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri $uri -Headers @{ 'X-Client-Id' = $script:Secrets.SpotifyClientId }
            if ($Key -eq 'SPOTIFY') { return Get-ResponseValue $r 'country' }
            if (-not $r.Success) { return $r.StatusValue }
            $o = ConvertFrom-JsonSafe $r.Body
            $status = Get-JsonPathValue $o 'status'
            $launched = Get-JsonPathValue $o 'is_country_launched'
            return Get-BooleanAvailability ($status -notin @(120, 320) -and $launched -ne $false)
        }
        'DEEZER' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.deezer.com/en/offers'
            if ($r.Success -and $r.Body -match "'country'\s*:\s*'([A-Za-z]{2})'") { return ConvertTo-CountryCode $Matches[1] }
            return $r.StatusValue
        }
        'REDDIT' {
            $agent = 'Reddit/Version 2025.29.0/Build 2529021/Android 13'
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method POST -Uri 'https://www.reddit.com/auth/v2/oauth/access-token/loid' -Headers @{ Authorization = "Basic $($script:Secrets.RedditBasicAccessToken)"; 'User-Agent' = $agent } -Body '{"scopes":["email"]}'
            if (-not $r.Success) { return $r.StatusValue }
            $token = Get-JsonPathValue (ConvertFrom-JsonSafe $r.Body) 'access_token'
            if (-not $token) { return $script:StatusNotAvailable }
            $body = '{"operationName":"UserLocation","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f07de258c54537e24d7856080f662c1b1268210251e5789c8c08f20d76cc8ab2"}}}'
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method POST -Uri 'https://gql-fed.reddit.com' -Headers @{ Authorization = "Bearer $token"; 'User-Agent' = $agent } -Body $body
            return Get-ResponseValue $r 'data.userLocation.countryCode'
        }
        'DISNEY_PLUS' {
            return Get-ResponseValue (Invoke-DisneyRequest $IpVersion) 'extensions.sdk.session.location.countryCode'
        }
        'GEMINI_SUPPORTED' {
            $countryCode = Invoke-CustomLookup -Key GOOGLE -IpVersion $IpVersion
            if ($countryCode -notmatch '^[A-Z]{2}$') { return $script:StatusNotAvailable }
            $countryResponse = Invoke-IpRequest -IpVersion 4 -Uri "https://www.apicountries.com/alpha/$countryCode"
            $countryName = Get-JsonPathValue (ConvertFrom-JsonSafe $countryResponse.Body) 'name'
            if (-not $countryName) { return $script:StatusNotAvailable }
            $regions = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://ai.google.dev/gemini-api/docs/available-regions.md.txt'
            if (-not $regions.Success) { return $regions.StatusValue }
            return Get-BooleanAvailability ($regions.Body -match "(?im)^-\s+$([regex]::Escape([string]$countryName))\s*$")
        }
        'REDDIT_GUEST_ACCESS' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.reddit.com'
            return Get-BooleanAvailability ($r.StatusCode -ne 403 -and $r.Success)
        }
        'YOUTUBE_PREMIUM' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.youtube.com/premium' -Headers @{ Cookie = "SOCS=$($script:Secrets.YouTubeSocsCookie)"; 'Accept-Language' = 'en-US,en;q=0.9' }
            if (-not $r.Success) { return $r.StatusValue }
            return Get-BooleanAvailability ($r.Body -notmatch '(?i)youtube premium is not available in your country')
        }
        'GOOGLE_SEARCH_CAPTCHA' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.google.com/search?q=cats' -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' }
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '(?i)unusual traffic from|is blocked|unaddressed abuse') { return 'Yes' }
            return 'No'
        }
        'DISNEY_PLUS_ACCESS' {
            $r = Invoke-DisneyRequest $IpVersion
            if (-not $r.Success) { return $r.StatusValue }
            $o = ConvertFrom-JsonSafe $r.Body
            $errors = Get-JsonPathValue $o 'errors'
            $supported = Get-JsonPathValue $o 'extensions.sdk.session.inSupportedLocation'
            return Get-BooleanAvailability ((-not $errors -or $errors.Count -eq 0) -and $supported -eq $true)
        }
        'AMAZON_PRIME' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.primevideo.com'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '"currentTerritory"\s*:\s*"([A-Za-z]{2})"') { return ConvertTo-CountryCode $Matches[1] }
            if ($r.Body -match '(?i)isServiceRestricted') { return 'No' }
            return $script:StatusNotAvailable
        }
        'APPLE' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://gspe1-ssl.ls.apple.com/pep/gcc'
            if (-not $r.Success) { return $r.StatusValue }
            return ConvertTo-CountryCode $r.Body
        }
        'STEAM' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method HEAD -Uri 'https://store.steampowered.com'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Headers -match '(?i)steamCountry=([^%;,\s]+)') { return ConvertTo-CountryCode $Matches[1] }
            return $script:StatusNotAvailable
        }
        'TIKTOK' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.tiktok.com/api/v1/web-cookie-privacy/config?appId=1988'
            return Get-ResponseValue $r 'body.appProps.region'
        }
        'OOKLA_SPEEDTEST' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.speedtest.net/api/js/config-sdk'
            return Get-ResponseValue $r 'location.countryCode'
        }
        'JETBRAINS' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://data.services.jetbrains.com/geo'
            return Get-ResponseValue $r 'code'
        }
        'PLAYSTATION' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Method HEAD -Uri 'https://www.playstation.com'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Headers -match '(?i)(?:^|[,;\s])country=([A-Za-z]{2})') { return ConvertTo-CountryCode $Matches[1] }
            return $script:StatusNotAvailable
        }
        'MICROSOFT' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://login.live.com'
            if ($r.Success -and $r.Body -match '"sRequestCountry"\s*:\s*"([^"]+)"') { return ConvertTo-CountryCode $Matches[1] }
            return $r.StatusValue
        }
        'BING' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.bing.com/search?q=cats'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match 'cn\.bing\.com') { return 'CN' }
            if ($r.Body -match 'Region\s*:\s*"([A-Za-z]{2})') {
                $region = ConvertTo-CountryCode $Matches[1]
                if ($region -ne 'WW') { return $region }
            }
            return Invoke-CustomLookup -Key MICROSOFT -IpVersion $IpVersion
        }
        'CLOUDFLARE_CDN' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://speed.cloudflare.com/meta' -Headers @{ Referer = 'https://speed.cloudflare.com' }
            if (-not $r.Success) { return $r.StatusValue }
            $iata = Get-JsonPathValue (ConvertFrom-JsonSafe $r.Body) 'colo.iata'
            return Get-IataCountry $iata
        }
        'YOUTUBE_CDN' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://redirector.googlevideo.com/report_mapping?di=no'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '(?i)=>\s+([a-z]{3})[a-z0-9]*\b') { return Get-IataCountry $Matches[1] }
            return $script:StatusNotAvailable
        }
        'NETFLIX_CDN' {
            $uri = "https://api.fast.com/netflix/speedtest/v2?https=true&token=$($script:Secrets.NetflixApiKey)&urlCount=1"
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri $uri
            return Get-ResponseValue $r 'targets.0.location.country'
        }
        default { return $script:StatusNotAvailable }
    }
}

function ConvertTo-ResultRow {
    param([string]$Service, [AllowNull()][string]$V4, [AllowNull()][string]$V6)
    return [pscustomobject][ordered]@{
        service = $Service
        ipv4 = if ($V4) { $V4 } else { $null }
        ipv6 = if ($V6) { $V6 } else { $null }
    }
}

function Invoke-OneService {
    param([hashtable]$Service, [ValidateSet('primary', 'custom', 'cdn')][string]$Kind, [string]$ExternalV4, [string]$ExternalV6)

    Write-IpLog -Level Info -Message "Checking $($Service.Name)"
    $v4 = $null
    $v6 = $null
    if ($ExternalV4) {
        $v4 = if ($Kind -eq 'primary') { Invoke-PrimaryLookup $Service 4 $ExternalV4 } else { Invoke-CustomLookup $Service.Key 4 }
    }
    if ($ExternalV6) {
        $v6 = if ($Kind -eq 'primary') { Invoke-PrimaryLookup $Service 6 $ExternalV6 } else { Invoke-CustomLookup $Service.Key 6 }
    }
    return ConvertTo-ResultRow $Service.Name $v4 $v6
}

function Invoke-ServiceSet {
    param([array]$Services, [ValidateSet('primary', 'custom', 'cdn')][string]$Kind, [string]$ExternalV4, [string]$ExternalV6)

    $selected = @($Services | Where-Object {
        -not ($_.ContainsKey('Intrusive') -and $_.Intrusive -and -not $IncludeIntrusiveChecks)
    })
    $activity = switch ($Kind) {
        'primary' { 'Checking GeoIP services' }
        'custom' { 'Checking popular services' }
        'cdn' { 'Checking CDN services' }
    }
    $completed = 0
    Write-IpProgress -Activity $activity -Status "0 of $($selected.Count) completed" -PercentComplete 0
    if ($ThrottleLimit -eq 1 -or $DebugLog -or $selected.Count -le 1) {
        $sequentialRows = [System.Collections.Generic.List[object]]::new()
        foreach ($service in $selected) {
            $sequentialRows.Add((Invoke-OneService $service $Kind $ExternalV4 $ExternalV6))
            $completed++
            $percent = [Math]::Floor(($completed / $selected.Count) * 100)
            Write-IpProgress -Activity $activity -Status "$completed of $($selected.Count) completed: $($service.Name)" -PercentComplete $percent
        }
        return $sequentialRows.ToArray()
    }

    $work = for ($index = 0; $index -lt $selected.Count; $index++) {
        [pscustomobject]@{ Index = $index; Service = $selected[$index] }
    }
    $scriptPathForWorker = $script:ScriptPath
    $workerResults = @($work | ForEach-Object -Parallel {
        $item = $_
        $workerParameters = @{
            Timeout = $using:Timeout
            ThrottleLimit = 1
            NoColor = $true
        }
        if ($using:Proxy) { $workerParameters.Proxy = $using:Proxy }
        if ($using:Interface) { $workerParameters.Interface = $using:Interface }
        . $using:scriptPathForWorker @workerParameters
        try {
            $row = Invoke-OneService $item.Service $using:Kind $using:ExternalV4 $using:ExternalV6
            [pscustomobject]@{ Index = $item.Index; Row = $row }
        } finally {
            foreach ($client in $script:Clients.Values) { $client.Dispose() }
            $script:Clients.Clear()
        }
    } -ThrottleLimit $ThrottleLimit | ForEach-Object {
        $completed++
        $percent = [Math]::Floor(($completed / $selected.Count) * 100)
        Write-IpProgress -Activity $activity -Status "$completed of $($selected.Count) completed: $($_.Row.service)" -PercentComplete $percent
        $_
    })
    return @($workerResults | Sort-Object Index | ForEach-Object Row)
}

function Get-CountryName {
    param([string]$Code)
    try { return ([System.Globalization.RegionInfo]::new($Code)).EnglishName } catch {
        switch ($Code) { 'EU' { 'European Union' }; 'WW' { 'Worldwide' }; 'XK' { 'Kosovo' }; default { 'Unknown' } }
    }
}

function Get-CountryStatistic {
    param([array]$Primary, [array]$Custom, [bool]$HasV4, [bool]$HasV6)

    $all = @($Primary) + @($Custom)
    $v4Codes = @($all | ForEach-Object {
        if ($null -ne $_ -and $_.PSObject.Properties['ipv4'] -and $_.ipv4 -cmatch '^[A-Z]{2}$') { $_.ipv4 }
    })
    $v6Codes = @($all | ForEach-Object {
        if ($null -ne $_ -and $_.PSObject.Properties['ipv6'] -and $_.ipv6 -cmatch '^[A-Z]{2}$') { $_.ipv6 }
    })
    $codes = @($v4Codes + $v6Codes | Sort-Object -Unique)
    return @($codes | ForEach-Object {
        $code = $_
        [pscustomobject][ordered]@{
            code = $code
            country = Get-CountryName $code
            ipv4Percent = if ($HasV4 -and $v4Codes.Count) { [Math]::Round((@($v4Codes | Where-Object { $_ -eq $code }).Count / $v4Codes.Count) * 100) } else { $null }
            ipv6Percent = if ($HasV6 -and $v6Codes.Count) { [Math]::Round((@($v6Codes | Where-Object { $_ -eq $code }).Count / $v6Codes.Count) * 100) } else { $null }
        }
    } | Sort-Object @{ Expression = { [Math]::Max([int]$_.ipv4Percent, [int]$_.ipv6Percent) }; Descending = $true }, code)
}

function ConvertTo-MaskedIpAddress {
    param([string]$Address)
    if ($Address -match '^(.+\.)\d+$') { return "$($Matches[1])x" }
    if ($Address -match ':') {
        $parts = $Address.Split(':')
        if ($parts.Count -gt 4) { return (($parts[0..3] -join ':') + ':…') }
    }
    return $Address
}

function Write-ColorText {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($NoColor -or [Console]::IsOutputRedirected) {
        if ($NoNewline) { [Console]::Out.Write($Text) } else { [Console]::Out.WriteLine($Text) }
    } else {
        $previous = [Console]::ForegroundColor
        try {
            [Console]::ForegroundColor = $Color
            if ($NoNewline) { [Console]::Out.Write($Text) } else { [Console]::Out.WriteLine($Text) }
        } finally { [Console]::ForegroundColor = $previous }
    }
}

function Get-ResultColor {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Service = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq $script:StatusNotAvailable) {
        return [ConsoleColor]::DarkGray
    }
    if ($Value -in @('No', $script:StatusDenied, $script:StatusRateLimit, $script:StatusServerError)) {
        return [ConsoleColor]::Red
    }
    if ($Service -eq 'Google Search Captcha' -and $Value -eq 'Yes') {
        return [ConsoleColor]::Red
    }
    return [ConsoleColor]::Green
}

function Get-ServiceColor {
    param([string]$Service, [array]$Values)

    $colors = @($Values | ForEach-Object { Get-ResultColor -Value $_ -Service $Service })
    if ($colors -contains [ConsoleColor]::Red) { return [ConsoleColor]::Red }
    if ($colors -contains [ConsoleColor]::DarkGray) { return [ConsoleColor]::DarkGray }
    return [ConsoleColor]::Green
}

function Write-ResultTable {
    param([string]$Title, [array]$Rows, [bool]$HasV4, [bool]$HasV6)
    Write-ColorText "`n$Title" Cyan
    $columns = @('Service')
    if ($HasV4) { $columns += 'IPv4' }
    if ($HasV6) { $columns += 'IPv6' }
    $widths = @{}
    foreach ($column in $columns) { $widths[$column] = $column.Length }
    foreach ($row in $Rows) {
        $widths.Service = [Math]::Max($widths.Service, ([string]$row.service).Length)
        if ($HasV4) { $widths.IPv4 = [Math]::Max($widths.IPv4, ([string]($row.ipv4 ?? $script:StatusNotAvailable)).Length) }
        if ($HasV6) { $widths.IPv6 = [Math]::Max($widths.IPv6, ([string]($row.ipv6 ?? $script:StatusNotAvailable)).Length) }
    }
    $header = $columns | ForEach-Object { $_.PadRight($widths[$_]) }
    Write-ColorText ($header -join '  ') White
    Write-ColorText (($columns | ForEach-Object { '-' * $widths[$_] }) -join '  ') DarkGray
    foreach ($row in $Rows) {
        $values = @()
        if ($HasV4) { $values += [string]($row.ipv4 ?? $script:StatusNotAvailable) }
        if ($HasV6) { $values += [string]($row.ipv6 ?? $script:StatusNotAvailable) }
        $serviceColor = Get-ServiceColor -Service $row.service -Values $values
        Write-ColorText ([string]$row.service).PadRight($widths.Service) $serviceColor -NoNewline
        if ($HasV4) {
            $v4 = [string]($row.ipv4 ?? $script:StatusNotAvailable)
            Write-ColorText '  ' Gray -NoNewline
            Write-ColorText $v4.PadRight($widths.IPv4) (Get-ResultColor $v4 $row.service) -NoNewline
        }
        if ($HasV6) {
            $v6 = [string]($row.ipv6 ?? $script:StatusNotAvailable)
            Write-ColorText '  ' Gray -NoNewline
            Write-ColorText $v6.PadRight($widths.IPv6) (Get-ResultColor $v6 $row.service) -NoNewline
        }
        [Console]::Out.WriteLine()
    }
}

function Write-StatisticsTable {
    param([array]$Statistics, [bool]$HasV4, [bool]$HasV6)
    if (@($Statistics).Count -eq 0) { return }
    $rows = @($Statistics | ForEach-Object {
        [pscustomobject]@{
            Code = $_.code
            Country = $_.country
            IPv4 = if ($null -ne $_.ipv4Percent) { "$($_.ipv4Percent)%" } else { '' }
            IPv6 = if ($null -ne $_.ipv6Percent) { "$($_.ipv6Percent)%" } else { '' }
        }
    })
    Write-ColorText "`nCountry consensus" Cyan
    $properties = @('Code', 'Country') + $(if ($HasV4) { 'IPv4' }) + $(if ($HasV6) { 'IPv6' })
    $rows | Format-Table -Property $properties -AutoSize | Out-String -Width 200 | Write-Output
}

function Invoke-IpRegion {
    if ($Help) {
        Get-Help -Name $PSCommandPath -Full
        return
    }
    if ($IPv4 -and $IPv6) { throw 'Use either -IPv4 or -IPv6, not both.' }
    if ($DebugLog) { Write-IpLog Info "ipregion.ps1 $($script:ScriptVersion) started" }

    Write-IpProgress -Activity 'IPRegion' -Status 'Detecting external IPv4 address' -PercentComplete 2
    $externalV4 = if (-not $IPv6) {
        try { Find-ExternalAddress 4 } catch {
            if ($IPv4) { throw }
            Write-IpLog Warning "IPv4 discovery failed: $($_.Exception.Message)"
            $null
        }
    } else { $null }
    Write-IpProgress -Activity 'IPRegion' -Status 'Detecting external IPv6 address' -PercentComplete 5
    $externalV6 = if (-not $IPv4) {
        try { Find-ExternalAddress 6 } catch {
            if ($IPv6) { throw }
            Write-IpLog Warning "IPv6 discovery failed: $($_.Exception.Message)"
            $null
        }
    } else { $null }
    if (-not $externalV4 -and -not $externalV6) { throw 'No usable IPv4 or IPv6 internet connection was detected.' }

    $normalizedGroup = if ($Group -eq 'GeoIP') { 'Primary' } else { $Group }
    $primary = @()
    $custom = @()
    $cdn = @()
    if ($normalizedGroup -in @('All', 'Primary')) { $primary = @(Invoke-ServiceSet $script:PrimaryServices primary $externalV4 $externalV6) }
    if ($normalizedGroup -in @('All', 'Custom')) { $custom = @(Invoke-ServiceSet $script:CustomServices custom $externalV4 $externalV6) }
    if ($normalizedGroup -in @('All', 'Cdn')) { $cdn = @(Invoke-ServiceSet $script:CdnServices cdn $externalV4 $externalV6) }

    Write-IpProgress -Activity 'IPRegion' -Status 'Preparing report' -PercentComplete 98
    $meta = if ($externalV4) { Get-NetworkInfo 4 } else { Get-NetworkInfo 6 }
    $statistics = @(Get-CountryStatistic $primary $custom ([bool]$externalV4) ([bool]$externalV6))
    $result = [pscustomobject][ordered]@{
        version = 1
        scriptVersion = $script:ScriptVersion
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        ipv4 = $externalV4
        ipv6 = $externalV6
        registeredCountry = $meta.RegisteredCountry
        asn = if ($meta.Asn) { "AS$($meta.Asn)" } else { $null }
        asnName = if ($meta.AsnName) { $meta.AsnName } else { $null }
        results = [pscustomobject][ordered]@{ primary = $primary; custom = $custom; cdn = $cdn }
        statistics = $statistics
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 10
        return
    }

    Write-ColorText 'IPRegion for Windows' Cyan
    Write-ColorText $script:ScriptUrl DarkGray
    if ($externalV4) { Write-ColorText ("IPv4: {0}, registered in {1}" -f (ConvertTo-MaskedIpAddress $externalV4), ($script:Metadata[4].RegisteredCountry ?? 'N/A')) White }
    if ($externalV6) { Write-ColorText ("IPv6: {0}, registered in {1}" -f (ConvertTo-MaskedIpAddress $externalV6), ($script:Metadata[6].RegisteredCountry ?? 'N/A')) White }
    Write-ColorText ("ASN: {0} {1}" -f ($result.asn ?? 'N/A'), ($result.asnName ?? '')) Yellow
    if ($custom.Count) { Write-ResultTable 'Popular services' $custom ([bool]$externalV4) ([bool]$externalV6) }
    if ($cdn.Count) { Write-ResultTable 'CDN services' $cdn ([bool]$externalV4) ([bool]$externalV6) }
    if ($primary.Count) { Write-ResultTable 'GeoIP services' $primary ([bool]$externalV4) ([bool]$externalV6) }
    Write-StatisticsTable $statistics ([bool]$externalV4) ([bool]$externalV6)
    if ($DebugLog) { [Console]::Error.WriteLine("Debug log: $($script:DebugPath)") }
}

try {
    if ($MyInvocation.InvocationName -ne '.') {
        Invoke-IpRegion
    }
} finally {
    if (Get-Command Write-IpProgress -ErrorAction SilentlyContinue) {
        Write-IpProgress -Activity 'IPRegion' -Status 'Completed' -PercentComplete 100 -Completed
    }
    foreach ($client in $script:Clients.Values) { $client.Dispose() }
    $script:Clients.Clear()
}
