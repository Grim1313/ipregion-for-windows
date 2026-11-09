#requires -Version 7.4

<#
.SYNOPSIS
Checks the apparent country of the current public IP across GeoIP providers,
popular services, and CDN endpoints.

.DESCRIPTION
Native Windows implementation of ipregion. It uses PowerShell and .NET only;
curl, jq, WSL, Git Bash, and third-party runtime modules are not required.

.PARAMETER Group
Selects one or several groups: Platforms, Availability, AI, Cdn, GeoIP.
All, Primary (GeoIP), and Custom (the original service set) remain supported.
Accepts arrays or comma-separated names. With no selectors, runs all safe checks.

.PARAMETER Service
Adds individual service IDs or names. Use -ListServices for exact IDs.
An explicitly selected intrusive check runs without enabling other intrusive checks.

.PARAMETER ListServices
Lists service IDs, groups, check types, and opt-in checks without network requests.

.PARAMETER IPv4
Runs only IPv4 checks. Alias: -4.

.PARAMETER IPv6
Runs only IPv6 checks. Alias: -6.

.PARAMETER Proxy
Uses an HTTP or SOCKS proxy. A value without a scheme is treated as SOCKS5.
The proxy chooses the target address family. Platform results use the proxy cell in JSON v2.

.PARAMETER SystemProxy
Explicitly uses the system/environment proxy configuration. The default is direct.

.PARAMETER Interface
Binds outgoing sockets to an address assigned to this Windows interface alias.

.PARAMETER Json
Writes JSON instead of the human-readable report. Defaults to the original v1 format.

.PARAMETER JsonVersion
Selects v1 (original scalar rows) or v2 (structured results and per-family metadata).

.PARAMETER Timeout
Total seconds per HTTP request, including its optional retry. Default: 5.

.PARAMETER GeoIpBreakdown
Shows every GeoIP provider instead of the compact consensus card.

.PARAMETER NoAttention
Hides the differences/failures card; JSON still includes all diagnostic information.

.PARAMETER Width
Maximum report width, 32 to 200 columns. Also constrained by the terminal width.

.PARAMETER Ascii
Uses ASCII borders and truncation markers for terminals without Unicode box drawing.

.PARAMETER NoColor
Disables colors. Redirected output and the NO_COLOR environment variable also disable colors.

.PARAMETER VerboseOutput
Writes masked diagnostics to stderr, including requests from parallel workers.

.PARAMETER DebugLog
Saves masked diagnostics locally while retaining bounded parallel execution.

.PARAMETER IncludeIntrusiveChecks
Enables Google CAPTCHA and sampled YouTube advertising checks in selected groups.

.PARAMETER YouTubeLanguage
Interface language for the optional YouTube No Ads observation. Default: ru.

.PARAMETER Help
Shows the full command reference without network requests.

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
    [string[]]$Group = @(),

    [Alias('s')]
    [string[]]$Service = @(),

    [switch]$ListServices,

    [ValidateSet(1, 2)]
    [int]$JsonVersion = 1,

    [switch]$SystemProxy,

    [switch]$GeoIpBreakdown,

    [switch]$NoAttention,

    [ValidateRange(32, 200)]
    [int]$Width = 100,

    [switch]$Ascii,

    [ValidatePattern('^[a-z]{2,3}(?:-[A-Za-z]{2})?$')]
    [string]$YouTubeLanguage = 'ru',

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

$script:ScriptVersion = '0.2.0'
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
$script:LastResponse = $null
$script:CheckEvidence = @{}
$script:ExternalAddresses = @{}
$script:Context = @{
    Clients = [System.Collections.Concurrent.ConcurrentDictionary[int, System.Net.Http.HttpClient]]::new()
    ClientGate = [System.Threading.SemaphoreSlim]::new(1, 1)
    Requests = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    Gates = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new()
    Logs = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}

$script:Secrets = @{
    SpotifyApiKey = '142b583129b2df829de3656f9eb484e6'
    SpotifyClientId = '9a8d2f0ce77a4e248bb71fefcb557637'
    NetflixApiKey = 'YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm'
    TwitchClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko'
    ChatGptStatsigApiKey = 'client-zUdXdSTygXJdzoE0sWTkP8GKTVsUMF2IRM7ShVO2JAG'
    YouTubeSocsCookie = 'CAI'
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
    @{ Key = 'IPAPI_CO'; Name = 'ipapi.co'; Url = 'https://ipapi.co/{ip}/json'; Path = 'country'; Headers = @{ Referer = 'https://ipapi.co/' } }
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


$script:AiEndpoints = @{
    OPENAI_API = @{ Name='OpenAI API'; Url='https://api.openai.com/v1/models'; Marker='unsupported_country_region_territory' }
    ANTHROPIC_API = @{ Name='Anthropic API'; Url='https://api.anthropic.com/v1/models'; Marker='Request not allowed' }
    GROK_API = @{ Name='Grok API'; Url='https://api.x.ai/v1/models'; Marker='not available in your region' }
    QWEN_API = @{ Name='Qwen API'; Url='https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models' }
    QWEN_CN_API = @{ Name='Qwen CN API'; Url='https://dashscope.aliyuncs.com/compatible-mode/v1/models' }
    KIMI_API = @{ Name='Kimi API'; Url='https://api.moonshot.ai/v1/models' }
    KIMI_CN_API = @{ Name='Kimi CN API'; Url='https://api.moonshot.cn/v1/models' }
    GLM_API = @{ Name='GLM API'; Url='https://api.z.ai/api/paas/v4/models' }
    GLM_CN_API = @{ Name='GLM CN API'; Url='https://open.bigmodel.cn/api/paas/v4/models' }
    MINIMAX_API = @{ Name='MiniMax API'; Url='https://api.minimax.io/v1/models' }
    MINIMAX_CN_API = @{ Name='MiniMax CN API'; Url='https://api.minimaxi.com/v1/models' }
    DOUBAO_API = @{ Name='Doubao API'; Url='https://ark.cn-beijing.volces.com/api/v3/models' }
    SILICONFLOW_API = @{ Name='SiliconFlow API'; Url='https://api.siliconflow.cn/v1/models' }
    DEEPSEEK_API = @{ Name='DeepSeek API'; Url='https://api.deepseek.com/models' }
}
$script:ExtraServices = @(
    @{ Key='CLAUDE'; Name='Claude'; Group='platforms'; Kind='country' }
    @{ Key='GEMINI_WEB'; Name='Gemini Web'; Group='ai'; Kind='availability' }
    @{ Key='YOUTUBE_NO_ADS'; Name='YouTube No Ads'; Group='availability'; Kind='observation'; Intrusive=$true }
) + @($script:AiEndpoints.Keys | Sort-Object | ForEach-Object {
    @{ Key=$_; Name=$script:AiEndpoints[$_].Name; Group='ai'; Kind='reachability' }
})
$availabilityKeys = @('YOUTUBE_MUSIC','REDDIT_GUEST_ACCESS','YOUTUBE_PREMIUM','GOOGLE_SEARCH_CAPTCHA','SPOTIFY_SIGNUP','DISNEY_PLUS_ACCESS')
foreach ($entry in $script:PrimaryServices) { $entry.Group='geoip'; $entry.Kind='country'; $entry.Legacy='primary' }
foreach ($entry in $script:CustomServices) {
    $entry.Group = if ($entry.Key -eq 'GEMINI_SUPPORTED') { 'ai' } elseif ($entry.Key -in $availabilityKeys) { 'availability' } else { 'platforms' }
    $entry.Kind = if ($entry.Group -eq 'platforms') { 'country' } else { 'availability' }
    $entry.Legacy='custom'
}
foreach ($entry in $script:CdnServices) { $entry.Group='cdn'; $entry.Kind='edge'; $entry.Legacy='cdn' }
foreach ($entry in $script:ExtraServices) { $entry.Legacy='custom' }
$script:Registry = @($script:PrimaryServices) + @($script:CustomServices) + @($script:CdnServices) + @($script:ExtraServices)
foreach ($entry in $script:Registry) { $entry.Id = $entry.Key.ToLowerInvariant() }

function Get-SelectedService {
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groups = @($Group | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if (-not $groups.Count -and -not $Service.Count) { $groups = @('all') }
    foreach ($name in $groups) {
        if ($name -notin @('all','primary','geoip','custom','platforms','availability','ai','cdn')) { throw "Unknown group '$name'. Use -ListServices." }
        foreach ($entry in $script:Registry) {
            if ($name -eq 'all' -or $entry.Group -eq $name -or ($name -eq 'primary' -and $entry.Group -eq 'geoip') -or ($name -eq 'custom' -and $entry -in $script:CustomServices)) {
                if (-not ($entry.ContainsKey('Intrusive') -and $entry.Intrusive -and -not $IncludeIntrusiveChecks)) { [void]$selected.Add($entry.Key) }
            }
        }
    }
    foreach ($name in @($Service | ForEach-Object { $_.Split(',') })) {
        $needle = ($name.Trim().ToLowerInvariant() -replace '[^a-z0-9/]', '')
        $found = @($script:Registry | Where-Object {
            $ids = @($_.Id, $_.Name, "$($_.Group)/$($_.Id)", "$($_.Group)/$($_.Name)")
            if ($_.Key -eq 'GEMINI_SUPPORTED') { $ids += @('gemini_api','Gemini API','ai/gemini_api') }
            @($ids | Where-Object { ($_.ToLowerInvariant() -replace '[^a-z0-9/]', '') -eq $needle }).Count -gt 0
        })
        if ($found.Count -ne 1) { throw "Unknown or ambiguous service '$name'. Use -ListServices for exact IDs." }
        [void]$selected.Add($found[0].Key)
    }
    return @($script:Registry | Where-Object { $selected.Contains($_.Key) })
}

function Protect-LogText {
    param([string]$Text)
    $text = [regex]::Replace($Text, '(?i)(https?://|socks[45]a?://)[^/@\s]+:[^/@\s]+@', '$1[credentials]@')
    $text = [regex]::Replace($text, '(?i)([?&](?:key|apikey|token|access_token)=)[^&\s]+', '$1[redacted]')
    $text = [regex]::Replace($text, '(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', { param($m) ConvertTo-MaskedIpAddress $m.Value })
    $text = [regex]::Replace($text, '(?i)(?<![\w:])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.]*(?:%\w+)?', {
        param($m)
        $ip = $null
        if ([Net.IPAddress]::TryParse($m.Value, [ref]$ip)) { ConvertTo-MaskedIpAddress $m.Value } else { $m.Value }
    })
    $text = [regex]::Replace($text, '(?i)(?:[a-f0-9]{0,4}%3a){2,}[a-f0-9%:.]*', '[address]')
    # Addresses encoded into query strings are just as sensitive as literal addresses.
    $text = [regex]::Replace($text, '(?i)([?&](?:ip|q|resource)=)[^&\s]+', '$1[address]')
    return $text
}

function Write-IpLog {
    param([string]$Level, [string]$Message)
    if (-not ($DebugLog -or $VerboseOutput)) { return }
    $line = '{0:o} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), (Protect-LogText $Message)
    $script:Context.Logs.Enqueue($line)
}

function Write-PendingLog {
    $line = ''
    while ($script:Context.Logs.TryDequeue([ref]$line)) {
        if ($DebugLog) { Add-Content -LiteralPath $script:DebugPath -Value $line -Encoding utf8NoBOM }
        if ($VerboseOutput) { [Console]::Error.WriteLine($line) }
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
        public static SocketsHttpHandler Create(AddressFamily family, string localAddress, string proxy, bool systemProxy = false)
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
                UseCookies = false,
                UseProxy = systemProxy
            };

            if (!string.IsNullOrWhiteSpace(proxy))
            {
                var uri = new Uri(proxy);
                var webProxy = new WebProxy(uri);
                if (!string.IsNullOrEmpty(uri.UserInfo))
                {
                    var credentials = uri.UserInfo.Split(new[] { ':' }, 2);
                    webProxy.Credentials = new NetworkCredential(Uri.UnescapeDataString(credentials[0]),
                        credentials.Length > 1 ? Uri.UnescapeDataString(credentials[1]) : "");
                }
                handler.Proxy = webProxy;
                handler.UseProxy = true;
            }

            IPAddress bindAddress = null;
            if (!string.IsNullOrWhiteSpace(localAddress))
                bindAddress = IPAddress.Parse(localAddress);

            handler.ConnectCallback = async (context, cancellationToken) =>
            {
                var socket = family == AddressFamily.Unspecified
                    ? new Socket(SocketType.Stream, ProtocolType.Tcp)
                    : new Socket(family, SocketType.Stream, ProtocolType.Tcp);
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
        Where-Object { $_.InterfaceAlias -eq $Interface -and -not $_.SkipAsSource -and $_.IPAddress -notmatch '^(127\.|169\.254\.|::1$|fe80:)' })
    if ($addresses.Count -eq 0) {
        throw "Interface '$Interface' has no usable $family address."
    }
    # Ask Windows for its preferred source on this exact interface when it has several addresses.
    $destination = if ($IpVersion -eq 4) { '1.1.1.1' } else { '2606:4700:4700::1111' }
    $route = @(Find-NetRoute -RemoteIPAddress $destination -InterfaceIndex $addresses[0].InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress -in $addresses.IPAddress })
    if ($route.Count) { return $route[0].IPAddress }
    return $addresses[0].IPAddress
}

function Initialize-IpClient {
    param([ValidateSet(0, 4, 6)][int]$IpVersion)
    Initialize-TransportType
    $isProxy = [bool]($Proxy -or $SystemProxy)
    $family = if ($isProxy -or $IpVersion -eq 0) { [Net.Sockets.AddressFamily]::Unspecified }
        elseif ($IpVersion -eq 4) { [Net.Sockets.AddressFamily]::InterNetwork }
        else { [Net.Sockets.AddressFamily]::InterNetworkV6 }
    $localAddress = if ($Interface) { Resolve-InterfaceAddress -IpVersion $IpVersion } else { $null }
    $proxyUri = $Proxy
    if ($proxyUri -and $proxyUri -notmatch '^[a-z][a-z0-9+.-]*://') { $proxyUri = "socks5://$proxyUri" }
    $handler = [IpRegion.TransportFactory]::Create($family, $localAddress, $proxyUri, [bool]$SystemProxy)
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $client.MaxResponseContentBufferSize = 16MB
    return $client
}

function Get-IpClient {
    param([ValidateSet(0, 4, 6)][int]$IpVersion)
    $key = if ($Proxy -or $SystemProxy) { 0 } else { $IpVersion }
    $script:Context.ClientGate.Wait()
    try {
        if (-not $script:Context.Clients.ContainsKey($key)) {
            $script:Context.Clients[$key] = Initialize-IpClient -IpVersion $key
        }
        return $script:Context.Clients[$key]
    } finally { [void]$script:Context.ClientGate.Release() }
}

function Get-HttpStatusValue {
    param([int]$StatusCode)

    if ($StatusCode -eq 403) { return $script:StatusDenied }
    if ($StatusCode -eq 429) { return $script:StatusRateLimit }
    if ($StatusCode -ge 500) { return $script:StatusServerError }
    if ($StatusCode -ge 400) { return $script:StatusNotAvailable }
    return $null
}

function Get-RequestFailureReason {
    param($Response)
    if (-not $Response) { return 'unexpected response' }
    if ($Response.Error) { return [string]$Response.Error }
    switch ([int]$Response.StatusCode) {
        0 { return 'network error' }
        402 { return 'daily limit used up' }
        403 { return 'access denied (403)' }
        429 { return 'rate limited (429)' }
    }
    if ($Response.StatusCode -ge 400) { return "HTTP $($Response.StatusCode)" }
    return 'unexpected response'
}

function Invoke-HttpRequest {
    param([int]$IpVersion, [string]$Method, [string]$Uri, [hashtable]$Headers,
        [AllowNull()][string]$Body, [string]$ContentType, [int]$RetryCount)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $responseData = $null
    # One deadline covers both attempts, rather than doubling -Timeout.
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($Timeout))
    try {
        $client = Get-IpClient $IpVersion
        for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
            try {
                if (-not $Headers.ContainsKey('User-Agent')) { [void]$request.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent) }
                foreach ($header in $Headers.GetEnumerator()) { [void]$request.Headers.TryAddWithoutValidation([string]$header.Key, [string]$header.Value) }
                if ($Body) { $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, $ContentType) }
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseContentRead, $cts.Token).GetAwaiter().GetResult()
                try {
                    $code = [int]$response.StatusCode
                    $responseData = [pscustomobject]@{
                        Success = $code -ge 200 -and $code -lt 300
                        StatusCode = $code; StatusValue = Get-HttpStatusValue $code
                        Body = if ($Method -eq 'HEAD') { '' } else { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
                        Headers = (@(foreach ($header in $response.Headers) {
                            foreach ($value in $header.Value) { "$($header.Key): $value" }
                        }) -join "`r`n") + "`r`n" + $response.Content.Headers.ToString()
                        FinalUri = $response.RequestMessage.RequestUri.AbsoluteUri
                        Error = $null; DurationMs = 0
                    }
                } finally { $response.Dispose() }
                # Do not retry throttling, authorization failures, or stateful POSTs.
                if ($code -notin @(502, 503, 504) -or $Method -eq 'POST') { break }
            } catch {
                $errorObject = $_.Exception
                while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
                $reason = if ($cts.IsCancellationRequested -or $errorObject -is [OperationCanceledException]) { 'timeout' }
                    elseif ($errorObject -is [Security.Authentication.AuthenticationException]) { 'TLS error' }
                    elseif ($errorObject -is [Net.Sockets.SocketException]) {
                        if ($errorObject.SocketErrorCode -in @('HostNotFound', 'NoData', 'TryAgain')) { 'DNS error' } else { 'connection failed' }
                    } else { 'network error' }
                $responseData = [pscustomobject]@{ Success=$false; StatusCode=0; StatusValue='N/A'; Body=''; Headers=''; FinalUri=$Uri; Error=$reason; DurationMs=0 }
                if ($cts.IsCancellationRequested -or $Method -eq 'POST') { break }
            } finally { $request.Dispose() }
            if ($attempt -lt $RetryCount) {
                try { [Threading.Tasks.Task]::Delay(100, $cts.Token).GetAwaiter().GetResult() } catch { break }
            }
        }
    } catch {
        $responseData = [pscustomobject]@{ Success=$false; StatusCode=0; StatusValue='N/A'; Body=''; Headers=''; FinalUri=$Uri; Error='transport unavailable'; DurationMs=0 }
    } finally { $cts.Dispose() }
    $responseData.DurationMs = $watch.ElapsedMilliseconds
    Write-IpLog Debug "$Method $Uri transport=$IpVersion HTTP=$($responseData.StatusCode) $($responseData.Error) $($responseData.DurationMs)ms"
    return $responseData
}

function Invoke-IpRequest {
    param(
        [ValidateSet(0, 4, 6)][int]$IpVersion,
        [ValidateSet('GET', 'POST', 'HEAD')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][string]$Body,
        [string]$ContentType = 'application/json',
        [ValidateRange(0, 2)][int]$RetryCount = 1,
        [switch]$NoCache
    )
    $transport = if ($Proxy -or $SystemProxy) { 0 } else { $IpVersion }
    $signature = @($transport, $Proxy, [bool]$SystemProxy, $Interface, $Method, $Uri, $Body, $ContentType, $Timeout, $RetryCount) + @(
        $Headers.Keys | Sort-Object | ForEach-Object { "${_}:$($Headers[$_])" }
    )
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($signature | ConvertTo-Json -Compress))))
    $gate = $null
    if (-not $script:Context.Gates.TryGetValue($key, [ref]$gate)) {
        $candidate = [Threading.SemaphoreSlim]::new(1, 1)
        $gate = $script:Context.Gates.GetOrAdd($key, $candidate)
        if (-not [object]::ReferenceEquals($gate, $candidate)) { $candidate.Dispose() }
    }
    $gate.Wait()
    try {
        if (-not $NoCache -and $script:Context.Requests.ContainsKey($key)) {
            $script:LastResponse = $script:Context.Requests[$key]
            Write-IpLog Debug "Cache hit: $Method $Uri transport=$transport"
            return $script:LastResponse
        }
        $r = Invoke-HttpRequest $transport $Method $Uri $Headers $Body $ContentType $RetryCount
        if (-not $NoCache) { $script:Context.Requests[$key] = $r }
        $script:LastResponse = $r
        return $r
    } finally { [void]$gate.Release() }
}

function ConvertFrom-JsonSafe {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return $Text | ConvertFrom-Json -Depth 128 -NoEnumerate -ErrorAction Stop } catch { return $null }
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
    if ($text -match '^[A-Z]{2}$') {
        if ($text -in @('EU','WW','XK')) { return $text }
        try { [void][Globalization.RegionInfo]::new($text); return $text } catch { return $script:StatusNotAvailable }
    }
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
    $services = if ($IpVersion -eq 4) { @('https://api4.ipify.org', 'https://v4.ident.me') }
        else { @('https://api6.ipify.org', 'https://v6.ident.me') }
    $answers = @($services | ForEach-Object {
        $response = Invoke-IpRequest -IpVersion $IpVersion -Uri $_ -RetryCount 0
        if ($response.Success -and (Test-AddressFamily $response.Body $IpVersion)) { [Net.IPAddress]::Parse($response.Body.Trim()).ToString() }
    })
    if ($answers.Count -gt 1 -and $answers[0] -ne $answers[1]) {
        Write-IpLog Warning "IPv$IpVersion identity services disagree; using first observed exit"
    }
    if ($answers.Count) { return $answers[0] }
    return $null
}

function Get-ResponseCookie {
    param([string]$Headers)
    return (@([regex]::Matches($Headers, '(?im)^set-cookie:\s*([^;\r\n]+)') | ForEach-Object { $_.Groups[1].Value }) -join '; ')
}

function Get-MaxMindResponse {
    param([int]$IpVersion, [string]$Address)
    $response = Invoke-IpRequest $IpVersion -Uri 'https://geoip.maxmind.com/geoip/v2.1/city/me' -Headers @{ Referer='https://www.maxmind.com' }
    if ($response.Success -and (Get-JsonPathValue (ConvertFrom-JsonSafe $response.Body) 'country.iso_code') -and -not ($Proxy -or $SystemProxy)) { return $response }
    # Explicit address lookup also avoids confusing a proxy-selected exit with the requested IP.
    $page = Invoke-IpRequest $IpVersion -Uri 'https://www.maxmind.com/en/geoip-web-services-demo'
    $csrf = if ($page.Body -match 'value="([0-9a-f]+)"\s+name="csrf_token"|name="csrf_token"\s+value="([0-9a-f]+)"') { @($Matches[1], $Matches[2]) -join '' } else { '' }
    if (-not $csrf) { return $response }
    $tokenResponse = Invoke-IpRequest $IpVersion -Method POST -Uri 'https://www.maxmind.com/en/geoip2/demo/token' -Headers @{
        'X-CSRF-Token'=$csrf; Cookie=Get-ResponseCookie $page.Headers
    }
    $token = Get-JsonPathValue (ConvertFrom-JsonSafe $tokenResponse.Body) 'token'
    if (-not $token) { return $tokenResponse }
    return Invoke-IpRequest $IpVersion -Uri "https://geoip.maxmind.com/geoip/v2.1/city/${Address}?demo=1" -Headers @{ Authorization="Bearer $token" }
}

function Get-NetworkInfo {
    param([ValidateSet(4, 6)][int]$IpVersion)
    if ($script:Metadata.ContainsKey($IpVersion)) { return $script:Metadata[$IpVersion] }
    $address = $script:ExternalAddresses[$IpVersion]
    $response = Get-MaxMindResponse $IpVersion $address
    $object = if ($response.Success) { ConvertFrom-JsonSafe $response.Body } else { $null }
    $country = ConvertTo-CountryCode (Get-JsonPathValue $object 'country.iso_code')
    $asn = Get-JsonPathValue $object 'traits.autonomous_system_number'
    $org = Get-JsonPathValue $object 'traits.autonomous_system_organization'
    $source = if ($asn) { 'MaxMind' } else { $null }
    $failure = if ($country -eq 'N/A') { Get-RequestFailureReason $response } else { $null }
    $registered = $null
    if ($address) {
        $rir = Invoke-IpRequest $IpVersion -Uri "https://stat.ripe.net/data/rir-stats-country/data.json?resource=$address"
        if ($rir.Success) { $registered = Get-JsonPathValue (ConvertFrom-JsonSafe $rir.Body) 'data.located_resources.0.location' }
        if (-not $asn) {
            $ripe = Invoke-IpRequest $IpVersion -Uri "https://stat.ripe.net/data/prefix-overview/data.json?resource=$address"
            if ($ripe.Success) {
                $data = ConvertFrom-JsonSafe $ripe.Body
                $asn = Get-JsonPathValue $data 'data.asns.0.asn'
                $org = Get-JsonPathValue $data 'data.asns.0.holder'
                if ($asn) { $source = 'RIPE' }
            }
        }
    }
    $metadata = [pscustomobject]@{
        Country=$country; RegisteredCountry=if ($registered) { Get-CountryName $registered } else { '' }
        RegisteredCode=$registered; Asn=$asn; AsnName=$org; Source=$source; MaxMindFailure=$failure; Response=$response
    }
    $script:Metadata[$IpVersion] = $metadata
    return $metadata
}

function Invoke-PrimaryLookup {
    param([hashtable]$Service, [ValidateSet(4, 6)][int]$AddressVersion, [string]$Address)

    if ($Service.Key -eq 'MAXMIND') {
        $info = Get-NetworkInfo -IpVersion $AddressVersion
        $script:LastResponse = $info.Response
        return $info.Country
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
    if ($Service.Key -eq 'IPINFO_IO' -and $AddressVersion -eq 6) {
        $uri = "https://v6.ipinfo.io/widget/demo/$([Uri]::EscapeDataString($Address))"
        $transportVersion = 6
    }
    if ($Service.Key -eq 'CLOUDFLARE') {
        $response = Invoke-IpRequest $transportVersion -Uri 'https://www.cloudflare.com/cdn-cgi/trace'
        if (-not $response.Success) { return $response.StatusValue }
        if ($response.Body -match '(?m)^ip=([^\r\n]+)') {
            $observedAddress=$null
            if (-not [Net.IPAddress]::TryParse($Matches[1].Trim(), [ref]$observedAddress)) { return 'N/A' }
            if (-not $observedAddress.Equals([Net.IPAddress]::Parse($Address))) {
                $script:CheckEvidence = @{ Status='skipped'; Reason='endpoint observed a different exit IP' }
                return 'N/A'
            }
        } else { return 'N/A' }
        if ($response.Body -match '(?m)^loc=([A-Z]{2})') { return $Matches[1] }
        return 'N/A'
    }
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

function Get-YouTubeNodeIata {
    param([string]$Node)
    foreach ($pattern in @('^([a-z]{3})[0-9]', '^[a-z]+-([a-z]{3})[0-9]', '^[a-z]{2}([a-z]{3})[a-z]-[a-z0-9]+$')) {
        if ($Node -match $pattern) { return $Matches[1].ToUpperInvariant() }
    }
    return $null
}

function Invoke-AiLookup {
    param([string]$Key, [int]$IpVersion)
    $endpoint = $script:AiEndpoints[$Key]
    $r = Invoke-IpRequest $IpVersion -Uri $endpoint.Url
    $data = ConvertFrom-JsonSafe $r.Body
    # Authentication responses prove endpoint reachability, not account/model access.
    $authResponse = ($data -and (Get-JsonPathValue $data 'error')) -or
        ($Key -eq 'DEEPSEEK_API' -and $r.Body.Trim() -eq 'Authentication Fails (governor)') -or
        ($Key -eq 'SILICONFLOW_API' -and (Get-JsonPathValue $data 'code') -eq 30014)
    if ($r.StatusCode -eq 401 -and $authResponse) {
        $script:CheckEvidence=@{ Status='reachable'; Reason='authentication required; account access not tested' }
        return 'Yes'
    }
    if ($r.StatusCode -eq 403 -and $endpoint.ContainsKey('Marker') -and $data -and $r.Body.Contains($endpoint.Marker)) {
        $script:CheckEvidence=@{ Status='region_block'; Reason='provider rejected the region' }; return 'No'
    }
    if ($r.StatusCode -eq 403) {
        $script:CheckEvidence=@{ Status='denied'; Reason='access denied; cause not confirmed' }; return 'Denied'
    }
    return $r.StatusValue
}

function ConvertTo-RegionName {
    param([string]$Name)
    return (([Net.WebUtility]::HtmlDecode($Name).ToLowerInvariant() -replace '[^\p{L} ]', ' ' -split '\s+' |
        Where-Object { $_ -and $_ -notin @('the','of','and') } | Sort-Object) -join ' ')
}

function Invoke-GeminiLookup {
    param([int]$IpVersion, [ValidateSet('api','web')][string]$Variant)
    $country = Invoke-CustomLookup GOOGLE $IpVersion
    if ($country -cnotmatch '^[A-Z]{2}$') { return 'N/A' }
    $url = if ($Variant -eq 'api') { 'https://ai.google.dev/gemini-api/docs/available-regions.md.txt' }
        else { 'https://support.google.com/gemini/answer/13575153?hl=en' }
    $r = Invoke-IpRequest $IpVersion -Uri $url
    if (-not $r.Success) { return $r.StatusValue }
    $names = @(if ($Variant -eq 'api') {
        @([regex]::Matches($r.Body, '(?m)^\s*[-*]\s+([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
    } else {
        $section = [regex]::Match($r.Body, '(?is)Supported countries\s*(?:&amp;|&)\s*territories.*?</h[23]>(.*?)(?:<h[23]|$)').Groups[1].Value
        @([regex]::Matches($section, '(?is)<li[^>]*>(.*?)</li>') | ForEach-Object { $_.Groups[1].Value -replace '<[^>]+>', '' })
    }
    )
    if ($names.Count -lt 20) { return 'N/A' }
    $aliases = @((Get-CountryName $country))
    $extra = @{ US=@('United States of America'); RU=@('Russia','Russian Federation'); KR=@('South Korea','Republic of Korea'); TW=@('Taiwan'); CZ=@('Czechia','Czech Republic'); TR=@('Turkey','Türkiye'); VN=@('Vietnam','Viet Nam'); GB=@('United Kingdom'); CD=@('Democratic Republic of the Congo','Congo - Kinshasa'); CG=@('Republic of the Congo','Congo - Brazzaville'); MO=@('Macau','Macao') }
    if ($extra.ContainsKey($country)) { $aliases += $extra[$country] }
    $normalized = @($names | ForEach-Object { ConvertTo-RegionName $_ })
    $matched=@($aliases | Where-Object { (ConvertTo-RegionName $_) -in $normalized }).Count -gt 0
    if (-not $matched) {
        # Alternate territory names prevent a naming mismatch from becoming a false region block.
        $cldr=Invoke-IpRequest $IpVersion -Uri 'https://cdn.jsdelivr.net/npm/cldr-localenames-full/main/en/territories.json'
        if (-not $cldr.Success) { return $cldr.StatusValue }
        $territories=Get-JsonPathValue (ConvertFrom-JsonSafe $cldr.Body) 'main.en.localeDisplayNames.territories'
        if (-not $territories) { return 'N/A' }
        $alternate=@($territories.PSObject.Properties | Where-Object Name -Match "^$country(?:-|$)" | ForEach-Object Value)
        if (-not $alternate.Count) { return 'N/A' }
        $matched=@($alternate | Where-Object { (ConvertTo-RegionName $_) -in $normalized }).Count -gt 0
    }
    $script:CheckEvidence = @{ Reason="official region list for $country; account eligibility not tested" }
    return Get-BooleanAvailability $matched
}

function Invoke-CustomLookup {
    param([string]$Key, [ValidateSet(4, 6)][int]$IpVersion)

    if ($script:AiEndpoints.ContainsKey($Key)) { return Invoke-AiLookup $Key $IpVersion }
    switch ($Key) {
        'CLAUDE' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://claude.ai/api/bootstrap' -Headers @{
                'User-Agent'='Claude com.anthropic.claude/1.261023.20 (Android 30) Claude/1.261023.20'; 'Anthropic-Client-Platform'='android'
            }
            return Get-ResponseValue $r 'statsig.user.country'
        }
        'GEMINI_WEB' { return Invoke-GeminiLookup $IpVersion web }
        'YOUTUBE_NO_ADS' {
            $headers = @{ Cookie="SOCS=CAI; PREF=hl=$YouTubeLanguage"; 'Accept-Language'=$YouTubeLanguage }
            $uri = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
            $first = Invoke-IpRequest $IpVersion -Uri $uri -Headers $headers -NoCache
            if (-not $first.Success) { return $first.StatusValue }
            $cookies = Get-ResponseCookie $first.Headers
            if (-not $cookies) { return 'N/A' }
            $headers.Cookie += "; $cookies"
            $r = Invoke-IpRequest $IpVersion -Uri $uri -Headers $headers -NoCache
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -notmatch 'ytInitialPlayerResponse' -or $r.Body -notmatch '"playabilityStatus"\s*:\s*\{\s*"status"\s*:\s*"OK"') { return 'N/A' }
            $script:CheckEvidence = @{ Reason="sampled video; interface language $YouTubeLanguage" }
            return Get-BooleanAvailability ($r.Body -notmatch 'SLOT_TYPE_PLAYER_BYTES')
        }
        'GOOGLE' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://accounts.google.com/v3/signin/identifier?flowName=GlifSetupAndroid'
            if ($r.Success -and $r.Body -match 'name="region"\s+value="([^"]+)"') { return ConvertTo-CountryCode $Matches[1] }
            return $r.StatusValue
        }
        'YOUTUBE' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.youtube.com/sw.js_data'
            if (-not $r.Success) { return $r.StatusValue }
            $payload = $r.Body -replace "^\)\]\}'\s*", ''
            $o = ConvertFrom-JsonSafe $payload
            return ConvertTo-CountryCode (Get-JsonPathValue $o '0.2.0.0.1')
        }
        'YOUTUBE_MUSIC' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://music.youtube.com/' -Headers @{ Cookie='SOCS=CAI'; 'Accept-Language'='en-US,en;q=0.9' }
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '(?i)YouTube Music is not available in your area') { return 'No' }
            if (($r.Body.Replace('\"', '"')) -match '"(?:browseId|pageType)"\s*:\s*"(?:FEmusic_home|MUSIC_PAGE_TYPE_HOME)"') {
                $script:CheckEvidence=@{ Reason='web interface detected; playback not tested' }
                return 'Yes'
            }
            return 'N/A'
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
            if ($status -in @(120, 320)) { return 'No' }
            if ($launched -is [bool]) { return Get-BooleanAvailability $launched }
            return 'N/A'
        }
        'DEEZER' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.deezer.com/en/offers'
            if ($r.Success -and $r.Body -match "'country'\s*:\s*'([A-Za-z]{2})'") { return ConvertTo-CountryCode $Matches[1] }
            return $r.StatusValue
        }
        'REDDIT' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://www.reddit.com/api/v1/not-found'
            if ($r.StatusCode -eq 403) { $script:CheckEvidence=@{ Status='ip_block'; Reason='access denied (403)' }; return 'Denied' }
            # This endpoint intentionally returns 404 with the location in its response.
            if ($r.StatusCode -in @(200,404) -and $r.Body -match 'country code:\s*([A-Z]{2})') { return $Matches[1] }
            return $r.StatusValue
        }
        'DISNEY_PLUS' {
            return Get-ResponseValue (Invoke-DisneyRequest $IpVersion) 'extensions.sdk.session.location.countryCode'
        }
        'GEMINI_SUPPORTED' {
            return Invoke-GeminiLookup $IpVersion api
        }
        'REDDIT_GUEST_ACCESS' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://www.reddit.com'
            if ($r.StatusCode -eq 403) { $script:CheckEvidence=@{ Status='ip_block'; Reason='access denied (403)' }; return 'Denied' }
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '(?i)<(?:shreddit-app|html)\b' -and $r.Body -match '(?i)reddit') { return 'Yes' }
            return 'N/A'
        }
        'YOUTUBE_PREMIUM' {
            $body = '{"context":{"client":{"clientName":"MWEB","clientVersion":"2.20261020.00.00","hl":"en"}},"browseId":"SPunlimited"}'
            $r = Invoke-IpRequest $IpVersion -Method POST -Uri 'https://www.youtube.com/youtubei/v1/browse' -Body $body
            if (-not $r.Success) { return $r.StatusValue }
            $data = ConvertFrom-JsonSafe $r.Body
            if (-not $data) { return 'N/A' }
            if ($r.Body -match '"premiumPurchaseButtonRenderer"\s*:') { return 'Yes' }
            if ($r.Body -match '(?i)not available in your country|not available in your region') { return 'No' }
            return 'N/A'
        }
        'GOOGLE_SEARCH_CAPTCHA' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://www.google.com/search?q=cats' -Headers @{ 'Accept-Language'='en-US,en;q=0.9' }
            if ($r.Body -match '(?i)unusual traffic from|g-recaptcha' -or $r.FinalUri -match '/sorry/') {
                $script:CheckEvidence=@{ Status='ip_block'; Reason='captcha' }; return 'Yes'
            }
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match 'id="(?:search|rso)"') { return 'No' }
            return 'N/A'
        }
        'DISNEY_PLUS_ACCESS' {
            $r = Invoke-DisneyRequest $IpVersion
            if (-not $r.Success) { return $r.StatusValue }
            $o = ConvertFrom-JsonSafe $r.Body
            $supported = Get-JsonPathValue $o 'extensions.sdk.session.inSupportedLocation'
            if ($supported -is [bool]) { return Get-BooleanAvailability $supported }
            if ($r.Body -match 'Forbidden location') { return 'No' }
            return 'N/A'
        }
        'AMAZON_PRIME' {
            $r = Invoke-IpRequest -IpVersion $IpVersion -Uri 'https://www.primevideo.com'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '"currentTerritory"\s*:\s*"([A-Za-z]{2})"') { return ConvertTo-CountryCode $Matches[1] }
            if ($r.Body -match '(?i)"isServiceRestricted"\s*:\s*true') { return 'No' }
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
            $r = Invoke-IpRequest $IpVersion -Uri 'https://speed.cloudflare.com/meta' -Headers @{ Referer='https://speed.cloudflare.com' }
            if (-not $r.Success) { return $r.StatusValue }
            $data = ConvertFrom-JsonSafe $r.Body
            $iata = Get-JsonPathValue $data 'colo.iata'
            $country = ConvertTo-CountryCode (Get-JsonPathValue $data 'colo.cca2')
            $script:CheckEvidence = @{ Iata=$iata }
            if ($country -ne 'N/A' -and $iata) { return "$country ($iata)" }
            return $country
        }
        'YOUTUBE_CDN' {
            $r = Invoke-IpRequest $IpVersion -Uri 'https://redirector.googlevideo.com/report_mapping?di=no'
            if (-not $r.Success) { return $r.StatusValue }
            if ($r.Body -match '=>\s+(\S+)') {
                $node = $Matches[1]
                $iata = Get-YouTubeNodeIata $node
                $script:CheckEvidence = @{ Node=$node; Iata=$iata }
                if ($iata) { return Get-IataCountry $iata }
            }
            return 'N/A'
        }
        'NETFLIX_CDN' {
            $uri = "https://api.fast.com/netflix/speedtest/v2?https=true&token=$($script:Secrets.NetflixApiKey)&urlCount=1"
            $r = Invoke-IpRequest $IpVersion -Uri $uri
            $url = Get-JsonPathValue (ConvertFrom-JsonSafe $r.Body) 'targets.0.url'
            if ($url -match '^https://ipv[46]-([a-z0-9]+-([a-z]{3})[0-9]+[a-z0-9-]*)\.') {
                $script:CheckEvidence = @{ Node=$Matches[1]; Iata=$Matches[2].ToUpperInvariant() }
            }
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

function Invoke-CheckCell {
    param([hashtable]$Entry, [int]$IpVersion, [string]$Address)
    $script:LastResponse = $null
    $script:CheckEvidence = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $value = if ($Entry.Group -eq 'geoip') { Invoke-PrimaryLookup $Entry $IpVersion $Address }
            else { Invoke-CustomLookup $Entry.Key $IpVersion }
    } catch {
        Write-IpLog Warning "Check $($Entry.Key) failed: $($_.Exception.Message)"
        $value = 'N/A'
        $script:CheckEvidence = @{ Status='error'; Reason='check failed' }
    }
    $country = $null; $access = $null; $reason = $null; $status = 'unknown'
    if ($value -cmatch '^([A-Z]{2})(?: \([A-Z]{3}\))?$' -and $Entry.Kind -in @('country','edge')) {
        $country=$Matches[1]; $status='ok'
    } elseif ($value -in @('Yes','No')) {
        $available = $value -eq 'Yes'
        if ($Entry.Key -eq 'GOOGLE_SEARCH_CAPTCHA') { $available = -not $available }
        $access=if ($available) { 'yes' } else { 'no' }
        $status=if ($available) { 'ok' } else { 'region_block' }
        if ($Entry.Kind -eq 'observation') { $status='observation' }
        if ($status -eq 'region_block') { $reason='region not supported' }
    } else {
        $reason = Get-RequestFailureReason $script:LastResponse
        $status = if ($script:LastResponse -and -not $script:LastResponse.Success) { 'error' } else { 'unknown' }
        if ($value -eq 'Denied') { $status='denied' }
    }
    $evidence = $script:CheckEvidence
    if ($evidence.ContainsKey('Status')) { $status=$evidence.Status }
    if ($evidence.ContainsKey('Reason')) { $reason=$evidence.Reason }
    if ($status -eq 'ip_block') { $access='ipblock' }
    $iata = if ($evidence.ContainsKey('Iata')) { $evidence.Iata } else { $null }
    $node = if ($evidence.ContainsKey('Node')) { $evidence.Node } else { $null }
    [pscustomobject][ordered]@{
        country=$country; access=$access; status=$status; reason=$reason
        httpStatus=if ($script:LastResponse) { $script:LastResponse.StatusCode } else { $null }
        elapsedMs=$watch.ElapsedMilliseconds; iata=$iata; node=$node
        legacyValue=if ($value) { [string]$value } else { 'N/A' }
    }
}

function Invoke-OneService {
    param([hashtable]$Service, [string]$Kind, [string]$ExternalV4, [string]$ExternalV6)
    Write-IpLog Info "Checking $($Service.Name)"
    $v4=$null; $v6=$null; $proxyCell=$null
    if (($Proxy -or $SystemProxy) -and $Service.Group -ne 'geoip') {
        $proxyCell=Invoke-CheckCell $Service 4 ''
    } else {
        if ($ExternalV4) { $v4=Invoke-CheckCell $Service 4 $ExternalV4 }
        if ($ExternalV6) { $v6=Invoke-CheckCell $Service 6 $ExternalV6 }
    }
    [pscustomobject][ordered]@{ id=$Service.Id; service=if ($Service.Key -eq 'YOUTUBE_NO_ADS') { "$($Service.Name) $YouTubeLanguage" } else { $Service.Name }; group=$Service.Group; kind=$Service.Kind; legacy=$Service.Legacy; ipv4=$v4; ipv6=$v6; proxy=$proxyCell }
}

function Invoke-ServiceSet {
    param([array]$Services, [string]$Kind, [string]$ExternalV4, [string]$ExternalV6)
    if (-not $Services.Count) { return @() }
    $completed=0; $total=$Services.Count
    $activity='Checking services'
    if ($ThrottleLimit -eq 1 -or $total -eq 1) {
        foreach ($entry in $Services) {
            Invoke-OneService $entry $Kind $ExternalV4 $ExternalV6
            $completed++
            Write-PendingLog
            Write-IpProgress $activity "$completed / $total - $($entry.Name)" ([int](100*$completed/$total))
        }
    } else {
        Initialize-TransportType
        $work = for ($index=0; $index -lt $total; $index++) { [pscustomobject]@{ Index=$index; Entry=$Services[$index] } }
        $sharedContext=$script:Context; $metadata=$script:Metadata; $addresses=$script:ExternalAddresses
        $scriptPathForWorker=$script:ScriptPath
        $parameters=@{ Timeout=$Timeout; Proxy=$Proxy; Interface=$Interface; SystemProxy=[bool]$SystemProxy; DebugLog=[bool]$DebugLog; VerboseOutput=[bool]$VerboseOutput; NoProgress=$true; NoColor=$true; YouTubeLanguage=$YouTubeLanguage }
        $rows=@($work | ForEach-Object -Parallel {
            $item=$_
            $workerParameters=$using:parameters
            . $using:scriptPathForWorker @workerParameters
            # Dispose the unused per-worker gate before adopting the shared context.
            $script:Context.ClientGate.Dispose()
            $script:Context=$using:sharedContext
            $script:Metadata=$using:metadata
            $script:ExternalAddresses=$using:addresses
            $row=Invoke-OneService $item.Entry $using:Kind $using:ExternalV4 $using:ExternalV6
            [pscustomobject]@{ Index=$item.Index; Row=$row }
        } -ThrottleLimit $ThrottleLimit | ForEach-Object {
            $completed++
            Write-PendingLog
            Write-IpProgress $activity "$completed / $total - $($_.Row.service)" ([int](100*$completed/$total))
            $_
        })
        $rows | Sort-Object Index | ForEach-Object Row
    }
    Write-IpProgress $activity 'Completed' 100 -Completed
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
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return '[address]' }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -eq 4) { return "$($bytes[0]).$($bytes[1]).$($bytes[2]).x" }
    return ((0..3 | ForEach-Object { '{0:x}' -f (([int]$bytes[2 * $_] -shl 8) + $bytes[2 * $_ + 1]) }) -join ':') + ':…'
}

function Write-ColorText {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($NoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) {
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
    $columns = @('Code', 'Country') + $(if ($HasV4) { 'IPv4' }) + $(if ($HasV6) { 'IPv6' })
    $widths = @{}
    foreach ($column in $columns) { $widths[$column] = $column.Length }
    foreach ($row in $rows) {
        foreach ($column in $columns) {
            $widths[$column] = [Math]::Max($widths[$column], ([string]$row.$column).Length)
        }
    }
    [Console]::Out.WriteLine(($columns | ForEach-Object { $_.PadRight($widths[$_]) }) -join '  ')
    [Console]::Out.WriteLine(($columns | ForEach-Object { ('-' * $widths[$_]) }) -join '  ')
    foreach ($row in $rows) {
        [Console]::Out.WriteLine(($columns | ForEach-Object { ([string]$row.$_).PadRight($widths[$_]) }) -join '  ')
    }
}


function Get-DisplayWidth {
    param([AllowEmptyString()][string]$Text)
    $width=0
    $elements=[Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $code=[char]::ConvertToUtf32($elements.GetTextElement(),0)
        $width += if (($code -ge 0x1100 -and $code -le 0x115f) -or ($code -ge 0x2e80 -and $code -le 0xa4cf) -or
            ($code -ge 0xac00 -and $code -le 0xd7a3) -or ($code -ge 0xf900 -and $code -le 0xfaff) -or
            ($code -ge 0xfe10 -and $code -le 0xfe6f) -or ($code -ge 0xff01 -and $code -le 0xff60) -or $code -ge 0x1f000) { 2 } else { 1 }
    }
    return $width
}

function Format-ReportText {
    param([AllowEmptyString()][string]$Text, [int]$Columns)
    # Remote organization/node names must never inject terminal control sequences.
    $clean=$Text -replace '\x1b\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if ((Get-DisplayWidth $clean) -le $Columns) { return $clean + (' ' * ($Columns-(Get-DisplayWidth $clean))) }
    $marker=if ($Ascii) { '~' } else { '…' }
    $builder=[Text.StringBuilder]::new(); $used=0
    $elements=[Globalization.StringInfo]::GetTextElementEnumerator($clean)
    while ($elements.MoveNext()) {
        $element=$elements.GetTextElement(); $size=Get-DisplayWidth $element
        if ($used+$size -gt $Columns-1) { break }
        [void]$builder.Append($element); $used+=$size
    }
    return $builder.ToString()+$marker+(' ' * [Math]::Max(0,$Columns-$used-1))
}

function Get-ReportLine {
    param([string]$Text, [ConsoleColor]$Color=[ConsoleColor]::Gray)
    [pscustomobject]@{ Text=$Text; Color=$Color }
}

function Get-WrappedReportLine {
    param([string]$Text, [int]$Columns, [ConsoleColor]$Color=[ConsoleColor]::Gray)
    $line=''
    foreach ($word in ($Text -split '\s+')) {
        if ((Get-DisplayWidth ($line+' '+$word)) -gt $Columns -and $line) { Get-ReportLine $line $Color; $line='' }
        if ((Get-DisplayWidth $word) -gt $Columns) {
            if ($line) { Get-ReportLine $line $Color; $line='' }
            Get-ReportLine (Format-ReportText $word $Columns) $Color
        } else { $line=if ($line) { "$line $word" } else { $word } }
    }
    if ($line) { Get-ReportLine $line $Color }
}

function Get-ReportCard {
    param([string]$Title, [array]$Lines, [int]$Columns)
    $h=if ($Ascii) { '-' } else { '─' }
    $v=if ($Ascii) { '|' } else { '│' }
    $tl=if ($Ascii) { '+' } else { '╭' }; $tr=if ($Ascii) { '+' } else { '╮' }
    $bl=if ($Ascii) { '+' } else { '╰' }; $br=if ($Ascii) { '+' } else { '╯' }
    $titleText=(Format-ReportText " $Title " ($Columns-4)).TrimEnd()
    Get-ReportLine ($tl+$h+$titleText+($h * ($Columns-3-(Get-DisplayWidth $titleText)))+$tr) Cyan
    foreach ($line in $Lines) { Get-ReportLine ($v+' '+(Format-ReportText $line.Text ($Columns-4))+' '+$v) $line.Color }
    Get-ReportLine ($bl+($h * ($Columns-2))+$br) DarkCyan
}

function Get-CellLabel {
    param($Cell)
    if (-not $Cell) { return '-' }
    if ($Cell.country) { return $Cell.country }
    switch ($Cell.status) {
        'reachable' { return 'REACH' }
        'region_block' { return 'BLOCK' }
        'ip_block' { return 'IP BLOCK' }
        'denied' { return 'DENIED' }
        'error' { return 'ERROR' }
        'skipped' { return '-' }
        'unknown' { return '?' }
        'observation' { if ($Cell.access -eq 'yes') { return 'NO ADS' }; return 'ADS' }
        default { if ($Cell.access -eq 'yes') { return 'OK' }; return '?' }
    }
}

function Get-CellColor {
    param($Cell)
    if (-not $Cell -or $Cell.status -eq 'skipped') { return [ConsoleColor]::DarkGray }
    if ($Cell.status -in @('region_block','ip_block','denied')) { return [ConsoleColor]::Red }
    if ($Cell.status -in @('unknown','error')) { return [ConsoleColor]::Yellow }
    if ($Cell.status -eq 'observation') { return [ConsoleColor]::Cyan }
    return [ConsoleColor]::Green
}

function Get-ServiceCardLine {
    param([array]$Rows, [int]$Columns, $Verdict=$null)
    $protocols=@('ipv4','ipv6','proxy' | Where-Object { $protocol=$_; @($Rows | Where-Object { $null -ne $_.$protocol }).Count })
    $content=$Columns-4
    $nameWidth=$content-($protocols.Count*9)
    if ($nameWidth -ge 20) { Get-ReportLine ((Format-ReportText 'SERVICE' $nameWidth)+(@($protocols | ForEach-Object { ' '+(Format-ReportText $_.ToUpperInvariant() 8) }) -join '')) DarkGray }
    foreach ($row in $Rows) {
        $name=if ($row.id -eq 'gemini_supported') { 'Gemini API' } elseif ($row.id -eq 'youtube_no_ads') { "YouTube No Ads $YouTubeLanguage" } else { $row.service }
        $color=[ConsoleColor]::Green
        $cells=foreach ($protocol in $protocols) {
            $cell=$row.$protocol; $cellColor=Get-CellColor $cell
            if ($Verdict -and $row.group -in @('geoip','platforms') -and $cell -and $cell.country -and $Verdict.$protocol.country -and $cell.country -ne $Verdict.$protocol.country) { $cellColor=[ConsoleColor]::Yellow }
            if ($cellColor -eq [ConsoleColor]::Red -or ($cellColor -eq [ConsoleColor]::Yellow -and $color -ne [ConsoleColor]::Red)) { $color=$cellColor }
            ' '+(Format-ReportText (Get-CellLabel $cell) 8)
        }
        if ($nameWidth -lt 20) {
            Get-WrappedReportLine $name $content White
            $values=@($protocols | ForEach-Object { "$($_.Replace('ipv','v')): $(Get-CellLabel $row.$_)" }) -join '  '
            Get-WrappedReportLine $values $content $color
        } else { Get-ReportLine ((Format-ReportText $name $nameWidth)+($cells -join '')) $color }
        if ($row.group -eq 'cdn') {
            foreach ($protocol in $protocols) {
                $cell=$row.$protocol
                if ($cell -and ($cell.iata -or $cell.node)) {
                    Get-WrappedReportLine "  ${protocol}: $($cell.iata) $($cell.node)" $content DarkGray
                }
            }
        }
    }
}

function Write-ReportCardPair {
    param([array]$Left, [array]$Right=@(), [int]$LeftWidth)
    $count=[Math]::Max($Left.Count,$Right.Count)
    for ($i=0; $i -lt $count; $i++) {
        if ($i -lt $Left.Count) { Write-ColorText $Left[$i].Text $Left[$i].Color -NoNewline }
        elseif ($Right.Count) { Write-ColorText (' ' * $LeftWidth) Gray -NoNewline }
        if ($Right.Count) {
            Write-ColorText '  ' Gray -NoNewline
            if ($i -lt $Right.Count) { Write-ColorText $Right[$i].Text $Right[$i].Color -NoNewline }
        }
        [Console]::Out.WriteLine()
    }
    [Console]::Out.WriteLine()
}

function Write-IpReport {
    param($Report)
    $columns=$Width
    if (-not [Console]::IsOutputRedirected) {
        try { if ([Console]::WindowWidth -gt 0) { $columns=[Math]::Min($columns,[Console]::WindowWidth) } } catch { Write-IpLog Debug 'Terminal width unavailable' }
    }
    $columns=[Math]::Max(32,$columns)
    $content=$columns-4
    $header=@(
        Get-ReportLine 'NETWORK LOCATION & ACCESS' White
        Get-ReportLine "Mode: $($Report.network.mode)$(if ($Report.network.interface) { ' / '+$Report.network.interface })" DarkGray
        foreach ($protocol in @('ipv4','ipv6')) {
            $network=$Report.$protocol
            if ($network) {
                $registration=if ([string]::IsNullOrWhiteSpace($network.registeredCountry)) { 'unknown' } else { $network.registeredCountry }
                Get-WrappedReportLine "$($protocol.ToUpperInvariant())  $(ConvertTo-MaskedIpAddress $network.ip)  /  registered: $registration" $content White
                Get-WrappedReportLine "      AS$($network.asn ?? '?')  $($network.org)" $content DarkGray
                $maxMindFailure=Get-JsonPathValue $network 'maxmindFailure'
                if ($maxMindFailure) { Get-WrappedReportLine "MaxMind: $maxMindFailure / ASN: $($network.asnSource ?? 'unavailable')" $content Yellow }
            }
        }
        foreach ($protocol in @('ipv4','ipv6','proxy')) {
            $summary=$Report.verdict.$protocol
            if (-not $summary.checked) { continue }
            $label=if ($summary.country) { "$($summary.country) - $(Get-CountryName $summary.country)" }
                elseif ($summary.tied.Count) { "tie: $($summary.tied -join ', ')" } else { 'no country answers' }
            Get-WrappedReportLine "$($protocol.ToUpperInvariant())  $label" $content Cyan
            Get-WrappedReportLine "      $($summary.agreed)/$($summary.answered) country answers agree | $($summary.errors) errors | $($summary.blocked) blocked" $content Gray
        }
    )
    Write-ReportCardPair @(Get-ReportCard "IPREGION  $($script:ScriptVersion)" $header $columns) -LeftWidth $columns
    $platforms=@($Report.rows | Where-Object group -eq platforms)
    $ai=@($Report.rows | Where-Object group -eq ai)
    if ($columns -ge 96 -and $platforms.Count -and $ai.Count) {
        $half=[int][Math]::Floor(($columns-2)/2)
        $rightWidth=$columns-$half-2
        $left=@(Get-ReportCard 'PLATFORMS' @(Get-ServiceCardLine $platforms $half $Report.verdict) $half)
        $right=@(Get-ReportCard 'AI / ENDPOINT ACCESS' @(Get-ServiceCardLine $ai $rightWidth $Report.verdict) $rightWidth)
        Write-ReportCardPair $left $right $half
    } else {
        foreach ($section in @(@{Title='PLATFORMS';Rows=$platforms},@{Title='AI / ENDPOINT ACCESS';Rows=$ai})) {
            if ($section.Rows.Count) { Write-ReportCardPair @(Get-ReportCard $section.Title @(Get-ServiceCardLine $section.Rows $columns $Report.verdict) $columns) -LeftWidth $columns }
        }
    }
    foreach ($name in @('availability','cdn','geoip')) {
        $rows=@($Report.rows | Where-Object group -eq $name)
        if (-not $rows.Count) { continue }
        $lines=if ($name -eq 'geoip' -and -not $GeoIpBreakdown -and -not $Service.Count) {
            @(
                foreach ($protocol in @('ipv4','ipv6')) {
                    $summary=Get-ProtocolSummary $rows $protocol
                    if ($summary.checked) {
                        $leader=if ($summary.country) { $summary.country } elseif ($summary.tied.Count) { 'tie: '+($summary.tied -join ', ') } else { 'unknown' }
                        Get-WrappedReportLine "$($protocol.ToUpperInvariant())  $leader / $($summary.agreed) of $($summary.answered) country answers agree; $($summary.errors) errors" $content Cyan
                    }
                }
                Get-WrappedReportLine 'Use -GeoIpBreakdown for every provider.' $content DarkGray
            )
        } else { @(Get-ServiceCardLine $rows $columns $Report.verdict) }
        Write-ReportCardPair @(Get-ReportCard $name.ToUpperInvariant() $lines $columns) -LeftWidth $columns
    }
    if (-not $NoAttention -and $Report.attention.Count) {
        $lines=@(foreach ($item in $Report.attention) {
            $color=if ($item.status -in @('ip_block','region_block','denied')) { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }
            Get-WrappedReportLine "$($item.service) [$($item.protocol)]$(if ($item.country) { ' '+$item.country }): $($item.reason)" $content $color
        })
        Write-ReportCardPair @(Get-ReportCard 'ATTENTION' $lines $columns) -LeftWidth $columns
    }
    foreach ($line in @(Get-WrappedReportLine 'OK available | REACH endpoint responds; account not tested | BLOCK region | IP BLOCK address | ? unknown | - not checked' $columns DarkGray)) { Write-ColorText $line.Text $line.Color }
    if ($platforms.Count -or $ai.Count) {
        foreach ($line in @(Get-WrappedReportLine 'Agreement is a count of responding services, not a probability of location.' $columns DarkGray)) { Write-ColorText $line.Text $line.Color }
    }
}

function ConvertTo-LegacyReport {
    param($Report)
    $arrays=@{ primary=@(); custom=@(); cdn=@() }
    foreach ($row in $Report.rows) {
        $arrays[$row.legacy] += ConvertTo-ResultRow $row.service $(if ($row.ipv4) { $row.ipv4.legacyValue }) $(if ($row.ipv6) { $row.ipv6.legacyValue })
    }
    $meta=if ($Report.ipv4) { $Report.ipv4 } else { $Report.ipv6 }
    [pscustomobject][ordered]@{
        version=1; scriptVersion=$script:ScriptVersion; generatedAt=$Report.generatedAt
        ipv4=if ($Report.ipv4) { $Report.ipv4.ip } else { $null }
        ipv6=if ($Report.ipv6) { $Report.ipv6.ip } else { $null }
        registeredCountry=if ($meta) { $meta.registeredCountry } else { '' }
        asn=if ($meta -and $meta.asn) { "AS$($meta.asn)" } else { $null }
        asnName=if ($meta) { $meta.org } else { $null }
        results=[pscustomobject][ordered]@{ primary=@($arrays.primary); custom=@($arrays.custom); cdn=@($arrays.cdn) }
        statistics=@(Get-CountryStatistic $arrays.primary $arrays.custom ([bool]$Report.ipv4) ([bool]$Report.ipv6))
    }
}

function Get-ProtocolSummary {
    param([array]$Rows, [string]$Protocol)
    $cells=@($Rows | Where-Object { $_.group -in @('geoip','platforms') -and $_.$Protocol -and $_.$Protocol.country } | ForEach-Object { $_.$Protocol })
    $groups=@($cells | Group-Object country | Sort-Object Count -Descending)
    $leaders=@(if ($groups.Count) { $groups | Where-Object Count -eq $groups[0].Count | ForEach-Object Name | Sort-Object })
    $country=if ($leaders.Count -eq 1) { $leaders[0] } else { $null }
    $all=@($Rows | Where-Object { $_.$Protocol } | ForEach-Object { $_.$Protocol })
    [pscustomobject][ordered]@{
        country=$country; tied=@(if ($leaders.Count -gt 1) { $leaders })
        agreed=if ($groups.Count) { $groups[0].Count } else { 0 }; answered=$cells.Count
        checked=$all.Count; errors=@($all | Where-Object status -in @('unknown','error','denied')).Count
        blocked=@($all | Where-Object status -in @('region_block','ip_block')).Count
    }
}

function Get-ReportAttention {
    param([array]$Rows, $Verdict)
    foreach ($row in $Rows) {
        foreach ($protocol in @('ipv4','ipv6','proxy')) {
            $cell=$row.$protocol
            if (-not $cell) { continue }
            $reason=$null
            if ($cell.status -in @('error','unknown','denied','skipped','ip_block','region_block')) { $reason=$cell.reason }
            if ($row.group -in @('geoip','platforms') -and $cell.country -and $Verdict.$protocol.country -and $cell.country -ne $Verdict.$protocol.country) { $reason='different country' }
            if ($reason) { [pscustomobject]@{ service=$row.service; protocol=$protocol; country=$cell.country; status=$cell.status; reason=$reason } }
        }
    }
}

function ConvertTo-VersionTwoReport {
    param($Report)
    $results=[ordered]@{}
    foreach ($name in @('platforms','availability','ai','cdn','geoip')) {
        $results[$name]=@($Report.rows | Where-Object group -eq $name | ForEach-Object {
            $row=[ordered]@{ id=$_.id; service=$_.service; kind=$_.kind }
            foreach ($protocol in @('ipv4','ipv6','proxy')) {
                $row[$protocol]=if ($_.$protocol) { $_.$protocol | Select-Object country,access,status,reason,httpStatus,elapsedMs,iata,node } else { $null }
            }
            [pscustomobject]$row
        })
    }
    [pscustomobject][ordered]@{
        version=2; scriptVersion=$script:ScriptVersion; generatedAt=$Report.generatedAt
        network=$Report.network; ipv4=$Report.ipv4; ipv6=$Report.ipv6
        verdict=$Report.verdict; attention=@($Report.attention); results=[pscustomobject]$results
    }
}

function ConvertTo-NetworkRecord {
    param([string]$Address, $Metadata)
    if (-not $Address) { return $null }
    [pscustomobject][ordered]@{
        ip=$Address; asn=$Metadata.Asn; org=$Metadata.AsnName; registeredCountry=$Metadata.RegisteredCountry
        registeredCode=Get-JsonPathValue $Metadata 'RegisteredCode'
        asnSource=Get-JsonPathValue $Metadata 'Source'
        maxmindFailure=Get-JsonPathValue $Metadata 'MaxMindFailure'
    }
}

function Invoke-IpRegion {
    if ($Help) { Get-Help -Name $script:ScriptPath -Full; return }
    if ($ListServices) {
        $script:Registry | ForEach-Object { [pscustomobject]@{ Id="$($_.Group)/$($_.Id)"; Service=$_.Name; Type=$_.Kind; OptIn=($_.ContainsKey('Intrusive') -and $_.Intrusive) } } | Format-Table -AutoSize
        return
    }
    if ($IPv4 -and $IPv6) { throw 'Use either -IPv4 or -IPv6, not both.' }
    if ($Proxy -and $SystemProxy) { throw 'Use either -Proxy or -SystemProxy, not both.' }
    if ($Interface -and ($Proxy -or $SystemProxy)) { throw '-Interface cannot be combined with a proxy: binding the proxy transport does not select its exit interface.' }
    if ($Proxy) {
        $uri=$null; $normalized=if ($Proxy -match '://') { $Proxy } else { "socks5://$Proxy" }
        if (-not [Uri]::TryCreate($normalized, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https','socks4','socks4a','socks5') -or -not $uri.Host -or $uri.AbsolutePath -notin @('','/') -or $uri.Query -or $uri.Fragment) { throw 'Invalid proxy URI. Use http(s):// or socks4(a)/socks5://host:port.' }
    }
    $selected=@(Get-SelectedService)
    foreach ($client in $script:Context.Clients.Values) { $client.Dispose() }
    $script:Context.Clients.Clear()
    foreach ($gate in $script:Context.Gates.Values) { $gate.Dispose() }
    $script:Context.Gates.Clear()
    $script:Context.Requests.Clear()
    $script:Metadata=@{}
    Write-IpLog Info "IPRegion $($script:ScriptVersion); proxy=$([bool]$Proxy); systemProxy=$SystemProxy; interface=$Interface"
    Write-IpProgress 'IPRegion' 'Detecting exit addresses' 2
    $externalV4=if (-not $IPv6) { Find-ExternalAddress 4 } else { $null }
    $externalV6=if (-not $IPv4) { Find-ExternalAddress 6 } else { $null }
    if (-not $externalV4 -and -not $externalV6) { throw 'No usable exit address detected for the selected network mode and address family.' }
    $script:ExternalAddresses=@{ 4=$externalV4; 6=$externalV6 }
    Write-PendingLog
    Write-IpProgress 'IPRegion' 'Looking up network registration' 5
    $metadataV4=if ($externalV4) { Get-NetworkInfo 4 } else { $null }
    $metadataV6=if ($externalV6) { Get-NetworkInfo 6 } else { $null }
    Write-PendingLog
    $rows=@(Invoke-ServiceSet $selected all $externalV4 $externalV6)
    $verdict=[pscustomobject]@{
        ipv4=Get-ProtocolSummary $rows ipv4; ipv6=Get-ProtocolSummary $rows ipv6; proxy=Get-ProtocolSummary $rows proxy
    }
    $report=[pscustomobject]@{
        generatedAt=(Get-Date).ToUniversalTime().ToString('o')
        network=[pscustomobject]@{ mode=if ($Proxy) { 'proxy' } elseif ($SystemProxy) { 'system-proxy' } else { 'direct' }; interface=$Interface }
        ipv4=ConvertTo-NetworkRecord $externalV4 $metadataV4
        ipv6=ConvertTo-NetworkRecord $externalV6 $metadataV6
        rows=$rows; verdict=$verdict; attention=@(Get-ReportAttention $rows $verdict)
    }
    Write-IpProgress 'IPRegion' 'Completed' 100 -Completed
    if ($Json) {
        if ($JsonVersion -eq 1) {
            if ($Proxy -or $SystemProxy) { [Console]::Error.WriteLine('Proxy-selected platform results require -JsonVersion 2; v1 address-family cells remain null.') }
            ConvertTo-LegacyReport $report | ConvertTo-Json -Depth 16
        } else { ConvertTo-VersionTwoReport $report | ConvertTo-Json -Depth 16 }
    } else { Write-IpReport $report }
    Write-PendingLog
    if ($DebugLog) { [Console]::Error.WriteLine("Debug log: $($script:DebugPath)") }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-IpRegion } finally {
        Write-IpProgress -Activity 'IPRegion' -Status 'Completed' -PercentComplete 100 -Completed
        Write-PendingLog
        foreach ($client in $script:Context.Clients.Values) { $client.Dispose() }
        foreach ($gate in $script:Context.Gates.Values) { $gate.Dispose() }
        $script:Context.ClientGate.Dispose()
    }
}
