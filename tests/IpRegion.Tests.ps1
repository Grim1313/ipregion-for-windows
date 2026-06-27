BeforeAll {
    . (Join-Path $PSScriptRoot '..\ipregion.ps1') -NoColor
}

Describe 'IPRegion core parsing' {
    It 'normalizes valid country codes' {
        ConvertTo-CountryCode ' us ' | Should -Be 'US'
    }

    It 'rejects malformed country values' {
        ConvertTo-CountryCode '<html>' | Should -Be 'N/A'
    }

    It 'keeps and traverses top-level JSON arrays' {
        $data = ConvertFrom-JsonSafe '[{"data":{"country":"DE"}}]'
        Get-JsonPathValue $data '0.data.country' | Should -Be 'DE'
    }

    It 'maps relevant HTTP errors to stable values' {
        Get-HttpStatusValue 403 | Should -Be 'Denied'
        Get-HttpStatusValue 429 | Should -Be 'Rate-limit'
        Get-HttpStatusValue 503 | Should -Be 'Server error'
        Get-HttpStatusValue 404 | Should -Be 'N/A'
        Get-HttpStatusValue 200 | Should -BeNullOrEmpty
    }

    It 'validates address families' {
        Test-AddressFamily '192.0.2.1' 4 | Should -BeTrue
        Test-AddressFamily '2001:db8::1' 6 | Should -BeTrue
        Test-AddressFamily '2001:db8::1' 4 | Should -BeFalse
        Test-AddressFamily 'not-an-ip' 4 | Should -BeFalse
    }
}

Describe 'IPRegion service registry' {
    It 'contains the current upstream services and selected fork additions' {
        $script:PrimaryServices.Count | Should -Be 18
        $script:CustomServices.Count | Should -Be 25
        $script:CdnServices.Count | Should -Be 3
        $script:PrimaryServices.Key | Should -Contain '2IP'
        $script:CustomServices.Key | Should -Contain 'YOUTUBE_MUSIC'
        $script:CustomServices.Key | Should -Contain 'DEEZER'
        $script:CustomServices.Key | Should -Contain 'AMAZON_PRIME'
        $script:CustomServices.Key | Should -Contain 'BING'
    }

    It 'uses IPv4 transport for an IPv6 address when the service requires it' {
        $script:ObservedVersion = $null
        Mock Invoke-IpRequest {
            param($IpVersion)
            $script:ObservedVersion = $IpVersion
            [pscustomobject]@{
                Success = $true
                StatusCode = 200
                StatusValue = $null
                Body = '{"country_code":"FR"}'
                Headers = ''
                Error = $null
            }
        }
        $service = @{ Key = 'TEST'; Name = 'test'; Url = 'https://example.test/{ip}'; Path = 'country_code'; IPv6OverIPv4 = $true }
        Invoke-PrimaryLookup $service 6 '2001:db8::1' | Should -Be 'FR'
        $script:ObservedVersion | Should -Be 4
    }
}

Describe 'IPRegion result model' {
    It 'calculates country consensus without counting availability values' {
        $primary = @(
            ConvertTo-ResultRow 'one' 'US' 'DE'
            ConvertTo-ResultRow 'two' 'US' 'DE'
            ConvertTo-ResultRow 'three' 'NL' 'N/A'
        )
        $custom = @(ConvertTo-ResultRow 'availability' 'Yes' 'No')
        $stats = @(Get-CountryStatistic $primary $custom $true $true)
        ($stats | Where-Object code -eq 'US').ipv4Percent | Should -Be 67
        ($stats | Where-Object code -eq 'NL').ipv4Percent | Should -Be 33
        ($stats | Where-Object code -eq 'DE').ipv6Percent | Should -Be 100
        $stats.code | Should -Not -Contain 'Yes'
    }

    It 'masks public addresses for human-readable output' {
        ConvertTo-MaskedIpAddress '192.0.2.123' | Should -Be '192.0.2.x'
        ConvertTo-MaskedIpAddress '2001:db8:1:2:3:4:5:6' | Should -Be '2001:db8:1:2:…'
    }

    It 'handles an empty statistics set' {
        { Write-StatisticsTable @() $true $false } | Should -Not -Throw
    }

    It 'prints country consensus heading before the table rows' {
        $writer = [System.IO.StringWriter]::new()
        $previousOutput = [Console]::Out
        try {
            [Console]::SetOut($writer)
            Write-StatisticsTable @(
                [pscustomobject]@{
                    code = 'US'
                    country = 'United States'
                    ipv4Percent = 100
                    ipv6Percent = $null
                }
            ) $true $false
            $output = $writer.ToString()
        } finally {
            [Console]::SetOut($previousOutput)
            $writer.Dispose()
        }
        $output.IndexOf('Country consensus') | Should -BeLessThan $output.IndexOf('Code')
    }

    It 'assigns result and service colors by failure severity' {
        Get-ResultColor 'No' | Should -Be ([ConsoleColor]::Red)
        Get-ResultColor 'Denied' | Should -Be ([ConsoleColor]::Red)
        Get-ResultColor 'N/A' | Should -Be ([ConsoleColor]::DarkGray)
        Get-ResultColor 'US' | Should -Be ([ConsoleColor]::Green)
        Get-ResultColor 'Yes' 'Google Search Captcha' | Should -Be ([ConsoleColor]::Red)
        Get-ServiceColor 'Example' @('US', 'Denied') | Should -Be ([ConsoleColor]::Red)
        Get-ServiceColor 'Example' @('US', 'N/A') | Should -Be ([ConsoleColor]::DarkGray)
    }
}

AfterAll {
    foreach ($client in $script:Clients.Values) { $client.Dispose() }
    $script:Clients.Clear()
}
