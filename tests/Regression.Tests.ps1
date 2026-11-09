[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification='Variables configure dot-sourced script functions in the current test scope.')]
param()

BeforeAll {
    if (-not ('IpRegion.Tests.SocksFixture' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'SocksFixture.cs') }
    function Get-TestResponse {
        param([string]$Body='{}', [int]$Code=200, [string]$ErrorText='')
        [pscustomobject]@{ Success=($Code -ge 200 -and $Code -lt 300); StatusCode=$Code; StatusValue=if ($Code -eq 0) { 'N/A' } else { Get-HttpStatusValue $Code }; Body=$Body; Headers=''; Error=$ErrorText; FinalUri='https://example.test/'; DurationMs=0 }
    }
    function Get-TestRow {
        param([string]$Id='one', [string]$Country='DE', [string]$Category='platforms')
        $cell=[pscustomobject]@{ country=$Country; access=$null; status='ok'; reason=$null; httpStatus=200; elapsedMs=1; iata=$null; node=$null; legacyValue=$Country }
        [pscustomobject]@{ id=$Id; service=$Id; group=$Category; kind='country'; legacy='custom'; ipv4=$cell; ipv6=$null; proxy=$null }
    }
    if (-not ('IpRegion.Tests.Handler' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
namespace IpRegion.Tests {
    public sealed class Handler : HttpMessageHandler {
        public int Hits;
        public string Body = "{\"country\":\"DE\"}";
        public int Code = 200;
        public int DelayMs = 50;
        public string UserAgent;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
            Interlocked.Increment(ref Hits);
            UserAgent = request.Headers.UserAgent.ToString();
            await Task.Delay(DelayMs, token);
            return new HttpResponseMessage((HttpStatusCode)Code) { Content = new StringContent(Body), RequestMessage = request };
        }
    }
}
'@
    }
}

Describe 'Regression suite' {
BeforeEach {
    . (Join-Path $PSScriptRoot '../ipregion.ps1') -NoColor -NoProgress
}

AfterEach {
    foreach ($client in $script:Context.Clients.Values) { $client.Dispose() }
    foreach ($gate in $script:Context.Gates.Values) { $gate.Dispose() }
    $script:Context.ClientGate.Dispose()
}

Describe 'Availability evidence and failure classification' {
    It '<Key> does not treat an empty JSON response as an availability verdict' -ForEach @(
        @{Key='SPOTIFY_SIGNUP'}, @{Key='YOUTUBE_PREMIUM'}, @{Key='YOUTUBE_MUSIC'}, @{Key='DISNEY_PLUS_ACCESS'}, @{Key='REDDIT_GUEST_ACCESS'}
    ) {
        Mock Invoke-IpRequest { Get-TestResponse }
        Invoke-CustomLookup $Key 4 | Should -Be 'N/A'
    }

    It '<Key> does not interpret HTML consent as availability' -ForEach @(
        @{Key='SPOTIFY_SIGNUP'}, @{Key='YOUTUBE_PREMIUM'}, @{Key='YOUTUBE_MUSIC'}, @{Key='DISNEY_PLUS_ACCESS'}
    ) {
        Mock Invoke-IpRequest { Get-TestResponse '<html>Please consent</html>' }
        Invoke-CustomLookup $Key 4 | Should -Be 'N/A'
    }

    It 'preserves a Reddit timeout instead of claiming a block' {
        Mock Invoke-IpRequest { Get-TestResponse '' 0 'timeout' }
        Invoke-CustomLookup REDDIT_GUEST_ACCESS 4 | Should -Be 'N/A'
    }

    It 'reads Reddit country from an intentional 404' {
        Mock Invoke-IpRequest { Get-TestResponse 'country code: FR' 404 }
        Invoke-CustomLookup REDDIT 4 | Should -Be 'FR'
    }

    It 'recognizes a Reddit IP block' {
        Mock Invoke-IpRequest { Get-TestResponse '<html>denied</html>' 403 }
        Invoke-CustomLookup REDDIT 4 | Should -Be 'Denied'
        $script:CheckEvidence.Status | Should -Be 'ip_block'
    }

    It 'requires a Premium purchase marker for a positive answer' {
        Mock Invoke-IpRequest { Get-TestResponse '{"contents":{"premiumPurchaseButtonRenderer":{}}}' }
        Invoke-CustomLookup YOUTUBE_PREMIUM 4 | Should -Be 'Yes'
    }

    It 'does not treat Prime isServiceRestricted=false as a regional block' {
        Mock Invoke-IpRequest { Get-TestResponse '{"isServiceRestricted":false}' }
        Invoke-CustomLookup AMAZON_PRIME 4 | Should -Be 'N/A'
    }

    It 'parses a YouTube anti-XSSI prefix without relying on line count' {
        Mock Invoke-IpRequest { Get-TestResponse ")]}'`n[[null,null,[[[null,`"DE`"]]]]]" }
        Invoke-CustomLookup YOUTUBE 4 | Should -Be 'DE'
    }

    It 'separates authenticated API reachability from full access' {
        Mock Invoke-IpRequest { Get-TestResponse '{"error":{"message":"Missing API key"}}' 401 }
        Invoke-CustomLookup OPENAI_API 4 | Should -Be 'Yes'
        $script:CheckEvidence.Status | Should -Be 'reachable'
        $script:CheckEvidence.Reason | Should -Match 'account access not tested'
    }

    It 'does not accept a gateway HTML 401 as an API response' {
        Mock Invoke-IpRequest { Get-TestResponse '<html>login</html>' 401 }
        Invoke-CustomLookup OPENAI_API 4 | Should -Be 'N/A'
    }

    It 'separates explicit regional denial from a generic 403' {
        Mock Invoke-IpRequest { Get-TestResponse '{"error":{"code":"unsupported_country_region_territory"}}' 403 }
        Invoke-CustomLookup OPENAI_API 4 | Should -Be 'No'
        $script:CheckEvidence.Status | Should -Be 'region_block'
    }

    It 'does not infer a region block from a generic API 403' {
        Mock Invoke-IpRequest { Get-TestResponse '{"error":"Forbidden"}' 403 }
        Invoke-CustomLookup OPENAI_API 4 | Should -Be 'Denied'
        $script:CheckEvidence.Status | Should -Be 'denied'
    }

    It 'handles the provider-specific <Key> authentication response' -ForEach @(
        @{Key='DEEPSEEK_API';Body='Authentication Fails (governor)'},
        @{Key='SILICONFLOW_API';Body='{"code":30014,"data":null,"message":"Token is invalid."}'}
    ) {
        $script:FixtureBody=$Body
        Mock Invoke-IpRequest { Get-TestResponse $script:FixtureBody 401 }
        Invoke-CustomLookup $Key 4 | Should -Be 'Yes'
        $script:CheckEvidence.Status | Should -Be 'reachable'
    }

    It 'parses deep but valid service JSON' {
        $nested='{"country":"DE"}'
        1..40 | ForEach-Object { $nested='{"data":'+$nested+'}' }
        ConvertFrom-JsonSafe $nested | Should -Not -BeNullOrEmpty
    }

    It 'accepts both Markdown region-list markers: <Marker>' -ForEach @(@{Marker='*'},@{Marker='-'}) {
        Mock Invoke-CustomLookup { 'US' } -ParameterFilter { $Key -eq 'GOOGLE' }
        $script:FixtureBody=(@("$Marker United States") + @(1..25 | ForEach-Object { "$Marker Country $_" })) -join "`n"
        Mock Invoke-IpRequest { Get-TestResponse $script:FixtureBody }
        Invoke-GeminiLookup 4 api | Should -Be 'Yes'
    }

    It 'does not turn a malformed region list into a negative answer' {
        Mock Invoke-CustomLookup { 'US' } -ParameterFilter { $Key -eq 'GOOGLE' }
        Mock Invoke-IpRequest { Get-TestResponse '<html>Consent</html>' }
        Invoke-GeminiLookup 4 api | Should -Be 'N/A'
    }

    It 'uses CLDR alternative names before claiming an unsupported region' {
        Mock Invoke-CustomLookup { 'PS' } -ParameterFilter { $Key -eq 'GOOGLE' }
        $script:FixtureBody=(@('* Palestine') + @(1..25 | ForEach-Object { "* Country $_" })) -join "`n"
        Mock Invoke-IpRequest {
            param($Uri)
            if ($Uri -like '*territories.json') { Get-TestResponse '{"main":{"en":{"localeDisplayNames":{"territories":{"PS":"Palestinian Territories","PS-alt-short":"Palestine"}}}}}' }
            else { Get-TestResponse $script:FixtureBody }
        }
        Invoke-GeminiLookup 4 api | Should -Be 'Yes'
    }

    It 'recognizes the escaped Music home navigation' {
        Mock Invoke-IpRequest { Get-TestResponse '{"navigation":"{\"browseId\":\"FEmusic_home\"}"}' }
        Invoke-CustomLookup YOUTUBE_MUSIC 4 | Should -Be 'Yes'
    }

    It 'parses supported CDN node formats: <Node>' -ForEach @(
        @{Node='ams17s01';Expected='AMS'}, @{Node='isp-fra12';Expected='FRA'}, @{Node='ruamsa-ab12';Expected='AMS'}, @{Node='unknown';Expected=$null}
    ) {
        Get-YouTubeNodeIata $Node | Should -Be $Expected
    }

    It 'uses Cloudflare country directly without airport lookup' {
        Mock Invoke-IpRequest { Get-TestResponse '{"colo":{"iata":"AMS","cca2":"NL"}}' }
        Mock Get-IataCountry { throw 'Unnecessary request' }
        Invoke-CustomLookup CLOUDFLARE_CDN 4 | Should -Be 'NL (AMS)'
        Should -Invoke Get-IataCountry -Times 0
    }
}

Describe 'Privacy and explicit network modes' {
    It 'uses the Windows-selected source address and excludes SkipAsSource addresses' {
        $Interface='Test Adapter'
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceAlias='Test Adapter'; InterfaceIndex=12; IPAddress='192.0.2.9'; SkipAsSource=$true }
            [pscustomobject]@{ InterfaceAlias='Test Adapter'; InterfaceIndex=12; IPAddress='192.0.2.1'; SkipAsSource=$false }
            [pscustomobject]@{ InterfaceAlias='Test Adapter'; InterfaceIndex=12; IPAddress='192.0.2.2'; SkipAsSource=$false }
        }
        Mock Find-NetRoute { [pscustomobject]@{IPAddress='192.0.2.2'} }
        Resolve-InterfaceAddress 4 | Should -Be '192.0.2.2'
        Should -Invoke Find-NetRoute -Times 1 -ParameterFilter { $InterfaceIndex -eq 12 }
    }

    It 'requires an exact interface alias instead of silently accepting wildcard matches' {
        $Interface='Test*'
        Mock Get-NetIPAddress { [pscustomobject]@{InterfaceAlias='Test Adapter';InterfaceIndex=12;IPAddress='192.0.2.1';SkipAsSource=$false} }
        { Resolve-InterfaceAddress 4 } | Should -Throw '*no usable*'
    }
    It 'sends the target name through an IPv4 SOCKS proxy even for an IPv6 lookup (auth=<Authentication>)' -ForEach @(@{Authentication=$false},@{Authentication=$true}) {
        $server=[IpRegion.Tests.SocksFixture]::new($Authentication)
        try {
            $Proxy=if ($Authentication) { "socks5://tester:p%40ss@127.0.0.1:$($server.Port)" } else { "socks5://127.0.0.1:$($server.Port)" }
            $r=Invoke-IpRequest 6 -Uri 'http://unresolvable.invalid/country' -RetryCount 0
            $r.Success | Should -BeTrue
            $r.Body | Should -Be '{"country":"DE"}'
            $server.Completion.GetAwaiter().GetResult()
            $server.AddressType | Should -Be 3
            $server.Destination | Should -Be 'unresolvable.invalid'
            if ($Authentication) {
                $server.Username | Should -Be 'tester'
                $server.Password | Should -Be 'p@ss'
            }
        } finally { $server.Dispose() }
    }
    It 'masks compressed and embedded IPv6 addresses: <Address>' -ForEach @(
        @{Address='2001:db8::1234'}, @{Address='::ffff:192.0.2.123'}, @{Address='2001:db8:0:0::abcd'}
    ) {
        ConvertTo-MaskedIpAddress $Address | Should -Not -Be $Address
        ConvertTo-MaskedIpAddress $Address | Should -Match '…$'
    }

    It 'redacts credentials, tokens, literal and encoded addresses in diagnostics' {
        $text=Protect-LogText 'https://alice:password@host.test/a?token=secret&ip=2001%3Adb8%3A%3A1234 192.0.2.123 2001:db8::abcd'
        $text | Should -Not -Match 'alice|password|secret|1234|abcd|192\.0\.2\.123'
    }

    It 'does not implicitly inherit the system proxy' {
        Initialize-TransportType
        $handler=[IpRegion.TransportFactory]::Create([Net.Sockets.AddressFamily]::InterNetwork, $null, $null)
        try { $handler.UseProxy | Should -BeFalse } finally { $handler.Dispose() }
    }

    It 'enables the system proxy only explicitly' {
        Initialize-TransportType
        $handler=[IpRegion.TransportFactory]::Create([Net.Sockets.AddressFamily]::Unspecified, $null, $null, $true)
        try { $handler.UseProxy | Should -BeTrue } finally { $handler.Dispose() }
    }

    It 'rejects ambiguous interface and proxy combinations before requests' {
        $Proxy='127.0.0.1:1080'; $Interface='Ethernet'
        Mock Find-ExternalAddress { throw 'Network must not be called' }
        { Invoke-IpRegion } | Should -Throw '*cannot be combined*'
        Should -Invoke Find-ExternalAddress -Times 0
    }

    It 'stores proxy-selected platform results only in proxy cells' {
        $Proxy='127.0.0.1:1080'
        Mock Invoke-CustomLookup { 'DE' }
        $row=Invoke-OneService ($script:Registry | Where-Object Key -eq STEAM) all '192.0.2.1' '2001:db8::1'
        $row.proxy.country | Should -Be 'DE'
        $row.ipv4 | Should -BeNullOrEmpty
        $row.ipv6 | Should -BeNullOrEmpty
        Should -Invoke Invoke-CustomLookup -Times 1 -Exactly
    }

    It 'does not label an unexpected Cloudflare proxy exit as the requested address' {
        Mock Invoke-IpRequest { Get-TestResponse "ip=2001:db8::1`nloc=DE`n" }
        Invoke-PrimaryLookup ($script:Registry | Where-Object Key -eq CLOUDFLARE) 4 '192.0.2.1' | Should -Be 'N/A'
        $script:CheckEvidence.Status | Should -Be 'skipped'
    }

    It 'compares IPv6 addresses numerically instead of rejecting an expanded representation' {
        Mock Invoke-IpRequest { Get-TestResponse "ip=2001:0db8:0000:0000:0000:0000:0000:0001`nloc=DE`n" }
        Invoke-PrimaryLookup ($script:Registry | Where-Object Key -eq CLOUDFLARE) 6 '2001:db8::1' | Should -Be 'DE'
    }
}

Describe 'Selective execution and JSON contracts' {
    It 'validates the golden v<Version> document against its schema' -ForEach @(@{Version=1},@{Version=2}) {
        Test-Json -LiteralPath (Join-Path $PSScriptRoot "fixtures/report-v$Version.json") -SchemaFile (Join-Path $PSScriptRoot "../schema/ipregion-v$Version.schema.json") | Should -BeTrue
    }

    It 'serializes a fresh v2 report with empty arrays and independent network metadata' {
        $rows=@(Get-TestRow)
        $v4=[pscustomobject]@{ip='192.0.2.1';asn=64500;org='V4';registeredCountry='Germany';registeredCode='DE';asnSource='RIPE';maxmindFailure=$null}
        $v6=[pscustomobject]@{ip='2001:db8::1';asn=64501;org='V6';registeredCountry='France';registeredCode='FR';asnSource='RIPE';maxmindFailure='daily limit used up'}
        $report=[pscustomobject]@{generatedAt='2026-11-09T00:00:00Z';network=[pscustomobject]@{mode='direct';interface=''};ipv4=$v4;ipv6=$v6;rows=$rows;verdict=[pscustomobject]@{ipv4=Get-ProtocolSummary $rows ipv4;ipv6=Get-ProtocolSummary $rows ipv6;proxy=Get-ProtocolSummary $rows proxy};attention=@()}
        $reportJson=ConvertTo-VersionTwoReport $report | ConvertTo-Json -Depth 16
        Test-Json -Json $reportJson -SchemaFile (Join-Path $PSScriptRoot '../schema/ipregion-v2.schema.json') | Should -BeTrue
        $parsed=$reportJson | ConvertFrom-Json
        $parsed.ipv4.asn | Should -Be 64500
        $parsed.ipv6.asn | Should -Be 64501
        $parsed.verdict.proxy.tied | Should -HaveCount 0
        $reportJson | Should -Not -Match 'legacyValue'
    }
    It 'supports multiple groups plus individual services without duplicates' {
        $Group=@('AI,CDN'); $Service=@('Steam','ai/openai_api')
        $selected=@(Get-SelectedService)
        @($selected | Where-Object Key -eq OPENAI_API).Count | Should -Be 1
        $selected.Key | Should -Contain 'STEAM'
        $selected.Key | Should -Contain 'NETFLIX_CDN'
        $selected.Key | Should -Not -Contain 'YOUTUBE_NO_ADS'
    }

    It 'does not run all groups when selecting a single service' {
        $Service=@('Steam')
        @(Get-SelectedService).Count | Should -Be 1
    }

    It 'retains the old Custom group including fork additions' {
        $Group=@('Custom')
        $selected=@(Get-SelectedService)
        $selected.Count | Should -Be 24
        foreach ($key in @('DEEZER','BING','AMAZON_PRIME','YOUTUBE_MUSIC')) { $selected.Key | Should -Contain $key }
    }

    It 'allows an explicitly requested intrusive check without enabling all intrusive checks' {
        $Service=@('youtube_no_ads')
        @(Get-SelectedService).Count | Should -Be 1
    }

    It 'rejects typos before network access' {
        $Group=@('AII')
        { Get-SelectedService } | Should -Throw '*Unknown group*'
    }

    It 'represents country ties without an arbitrary winner' {
        $summary=Get-ProtocolSummary @((Get-TestRow one DE),(Get-TestRow two FR)) ipv4
        $summary.country | Should -BeNullOrEmpty
        $summary.tied | Should -Be @('DE','FR')
        $summary.answered | Should -Be 2
    }

    It 'does not count availability rows as country votes' {
        $summary=Get-ProtocolSummary @((Get-TestRow one DE),(Get-TestRow two FR availability)) ipv4
        $summary.country | Should -Be 'DE'
        $summary.answered | Should -Be 1
    }

    It 'preserves v1 top-level fields, scalar rows and empty arrays' {
        $network=[pscustomobject]@{ ip='192.0.2.1'; asn=64500; org='Example'; registeredCountry='Germany' }
        $report=[pscustomobject]@{ generatedAt='2026-11-09T00:00:00Z'; ipv4=$network; ipv6=$null; rows=@(Get-TestRow) }
        $legacy=ConvertTo-LegacyReport $report
        @($legacy.PSObject.Properties.Name) | Should -Be @('version','scriptVersion','generatedAt','ipv4','ipv6','registeredCountry','asn','asnName','results','statistics')
        $legacy.version | Should -Be 1
        $legacy.asn | Should -Be 'AS64500'
        $legacy.results.custom[0].ipv4 | Should -Be 'DE'
        @($legacy.results.custom[0].PSObject.Properties.Name) | Should -Be @('service','ipv4','ipv6')
        $roundtrip=$legacy | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $roundtrip.results.primary | Should -HaveCount 0
        $roundtrip.results.cdn | Should -HaveCount 0
    }
}

Describe 'Network metadata fallback' {
    It 'gets ASN from RIPE when MaxMind is unavailable and keeps registration separate' {
        $script:ExternalAddresses=@{4='192.0.2.1'}
        Mock Get-MaxMindResponse { Get-TestResponse '{}' 402 }
        Mock Invoke-IpRequest {
            param($Uri)
            if ($Uri -match 'rir-stats-country') { Get-TestResponse '{"data":{"located_resources":[{"location":"NL"}]}}' }
            else { Get-TestResponse '{"data":{"asns":[{"asn":64500,"holder":"Example Network"}]}}' }
        }
        $info=Get-NetworkInfo 4
        $info.Asn | Should -Be 64500
        $info.Source | Should -Be 'RIPE'
        $info.RegisteredCode | Should -Be 'NL'
        $info.Country | Should -Be 'N/A'
        $info.MaxMindFailure | Should -Be 'daily limit used up'
    }

    It 'uses a demo token with cookies and looks up the explicit address' {
        Mock Invoke-IpRequest {
            param($Uri)
            if ($Uri -like '*/city/me') { Get-TestResponse '{}' 401 }
            elseif ($Uri -like '*geoip-web-services-demo') {
                $r=Get-TestResponse '<input value="abcd" name="csrf_token">'
                $r.Headers="Set-Cookie: session=example; Secure`r`n"
                $r
            } elseif ($Uri -like '*/demo/token') { Get-TestResponse '{"token":"fixture-token"}' 201 }
            else { Get-TestResponse '{"country":{"iso_code":"DE"}}' }
        }
        $r=Get-MaxMindResponse 4 '192.0.2.1'
        $r.Success | Should -BeTrue
        Should -Invoke Invoke-IpRequest -Times 1 -ParameterFilter { $Uri -like '*/demo/token' -and $Headers.Cookie -eq 'session=example' -and $Headers['X-CSRF-Token'] -eq 'abcd' }
        Should -Invoke Invoke-IpRequest -Times 1 -ParameterFilter { $Uri -like '*/city/192.0.2.1?demo=1' -and $Headers.Authorization -eq 'Bearer fixture-token' }
    }

    It 'keeps a useful MaxMind response when the token page format changes' {
        Mock Invoke-IpRequest {
            param($Uri)
            if ($Uri -like '*/city/me') { Get-TestResponse '{}' 402 } else { Get-TestResponse '<html>changed</html>' }
        }
        (Get-MaxMindResponse 4 '192.0.2.1').StatusCode | Should -Be 402
    }
}

Describe 'Bounded shared HTTP execution' {
    BeforeEach {
        $script:Handler=[IpRegion.Tests.Handler]::new()
        $script:Context.Clients[4]=[Net.Http.HttpClient]::new($script:Handler)
    }

    It 'reuses identical requests and distinguishes headers and bodies' {
        [void](Invoke-IpRequest 4 -Uri 'http://example.test/country')
        [void](Invoke-IpRequest 4 -Uri 'http://example.test/country')
        [void](Invoke-IpRequest 4 -Uri 'http://example.test/country' -Headers @{ 'X-Test'='different' })
        [void](Invoke-IpRequest 4 -Method POST -Uri 'http://example.test/country' -Body '{"a":1}')
        [void](Invoke-IpRequest 4 -Method POST -Uri 'http://example.test/country' -Body '{"a":2}')
        $script:Handler.Hits | Should -Be 4
    }

    It 'does not append the default user-agent to a service override' {
        [void](Invoke-IpRequest 4 -Uri 'http://example.test/ua' -Headers @{ 'User-Agent'='TestAgent/1.0' })
        $script:Handler.UserAgent | Should -Be 'TestAgent/1.0'
    }

    It 'shares in-flight requests across workers and keeps result ordering with debug enabled' {
        $DebugLog=$true
        $script:DebugPath=Join-Path $TestDrive 'debug.log'
        $script:Handler.DelayMs=200
        $entries=@(1..8 | ForEach-Object { @{Key="TEST$_"; Id="test$_"; Name="Test $_"; Group='geoip'; Kind='country'; Legacy='primary'; Url='http://example.test/shared'; Path='country'} })
        $rows=@(Invoke-ServiceSet $entries all '192.0.2.1' '')
        $rows.Count | Should -Be 8
        $rows.id | Should -Be @(1..8 | ForEach-Object { "test$_" })
        $script:Handler.Hits | Should -Be 1
        $rows.ipv4.country | Should -Be (@('DE')*8)
        Get-Content $script:DebugPath -Raw | Should -Match 'Cache hit'
    }

    It 'uses one timeout budget across attempts' {
        $Timeout=1; $script:Handler.DelayMs=5000
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $r=Invoke-IpRequest 4 -Uri 'http://example.test/slow'
        $r.Error | Should -Be 'timeout'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 2.5
        $script:Handler.Hits | Should -Be 1
    }

    It 'does not retry a throttled response' {
        $script:Handler.Code=429
        $r=Invoke-IpRequest 4 -Uri 'http://example.test/limit'
        $r.StatusValue | Should -Be 'Rate-limit'
        $script:Handler.Hits | Should -Be 1
    }
}

Describe 'Responsive console report' {
    It 'keeps every line within <Columns> columns' -ForEach @(@{Columns=32},@{Columns=48},@{Columns=80},@{Columns=100},@{Columns=120}) {
        $Width=$Columns
        $rows=@((Get-TestRow 'A very long platform service name' DE),(Get-TestRow 'OpenAI API' DE ai))
        $network=[pscustomobject]@{ ip='2001:db8::1234'; asn=64500; org='An extremely long organization name 日本語'; registeredCountry='Germany' }
        $verdict=[pscustomobject]@{ ipv4=Get-ProtocolSummary $rows ipv4; ipv6=Get-ProtocolSummary $rows ipv6; proxy=Get-ProtocolSummary $rows proxy }
        $report=[pscustomobject]@{ network=[pscustomobject]@{mode='direct';interface=''}; ipv4=$network; ipv6=$null; rows=$rows; verdict=$verdict; attention=@() }
        $writer=[IO.StringWriter]::new(); $previous=[Console]::Out
        try { [Console]::SetOut($writer); Write-IpReport $report } finally { [Console]::SetOut($previous) }
        $text=$writer.ToString(); $writer.Dispose()
        foreach ($line in ($text -split '\r?\n')) { Get-DisplayWidth $line | Should -BeLessOrEqual $Columns }
        $text | Should -Match 'IPREGION'
        $text | Should -Match 'PLATFORMS'
        $text | Should -Not -Match '1234'
    }

    It 'strips remote ANSI/control sequences without splitting Unicode graphemes' {
        $text=Format-ReportText "`e[31mA`n日本語" 8
        $text | Should -Not -Match '\x1b|\n'
        Get-DisplayWidth $text | Should -Be 8
    }

    It 'uses ASCII borders on request' {
        $Ascii=$true
        $card=@(Get-ReportCard 'TEST' @((Get-ReportLine 'OK')) 32)
        $card[0].Text | Should -Match '^\+-'
        ($card.Text -join '') | Should -Not -Match '[╭╮╰╯│─]'
    }
}

}
