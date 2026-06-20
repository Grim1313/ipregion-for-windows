# IPRegion for Windows

A native PowerShell implementation of [vernette/ipregion](https://github.com/vernette/ipregion) for Windows. It compares the apparent country of the current public IP across GeoIP providers, popular services, and CDN endpoints.

The implementation also incorporates selected fixes and service checks from [Davoyan/ipregion](https://github.com/Davoyan/ipregion).

## Requirements

- Windows 10, Windows 11, or Windows Server
- PowerShell 7.4 or newer
- Internet access to the services being checked

The runtime has no third-party dependencies. It does not require `curl`, `jq`, WSL, Git Bash, Docker, or external PowerShell modules.

## Usage

```powershell
# Run all checks
pwsh ./ipregion.ps1

# GeoIP providers only
pwsh ./ipregion.ps1 -Group Primary

# Popular services or CDN endpoints only
pwsh ./ipregion.ps1 -Group Custom
pwsh ./ipregion.ps1 -Group Cdn

# Force one address family
pwsh ./ipregion.ps1 -IPv4
pwsh ./ipregion.ps1 -IPv6

# Stable machine-readable output
pwsh ./ipregion.ps1 -Json

# SOCKS5 proxy; the scheme can be omitted
pwsh ./ipregion.ps1 -Proxy 127.0.0.1:1080

# Bind sockets to a Windows interface alias
pwsh ./ipregion.ps1 -Interface "Ethernet"

# Limit concurrency or force sequential processing
pwsh ./ipregion.ps1 -ThrottleLimit 4
pwsh ./ipregion.ps1 -ThrottleLimit 1

# Disable the interactive progress indicator
pwsh ./ipregion.ps1 -NoProgress
```

Short aliases compatible with the bash script are supported: `-g`, `-t`, `-4`, `-6`, `-p`, `-i`, `-j`, `-v`, and `-d`.

Use PowerShell help for the complete parameter reference:

```powershell
Get-Help ./ipregion.ps1 -Full
```

## Features

- Native IPv4 and IPv6 sockets with optional Windows interface binding
- HTTP and SOCKS proxy support through .NET
- External-IP validation using independent identity services
- Bounded concurrent checks with stable result ordering
- Interactive progress by phase and completed service count
- Color-coded service names and results for successful, failed, and unavailable checks
- 18 GeoIP providers, including 2ip.io from the Davoyan fork
- 25 popular-service checks, including YouTube Music, Deezer, Amazon Prime, and Bing
- Cloudflare, YouTube, and Netflix CDN checks
- Country consensus percentages
- Stable JSON schema for automation
- Explicit timeout, retry, HTTP error, malformed JSON, and partial-failure handling
- Local debug logs that do not upload themselves

Google Search CAPTCHA probing is excluded by default because it is intrusive and can itself affect rate limits. Enable it explicitly:

```powershell
pwsh ./ipregion.ps1 -IncludeIntrusiveChecks
```

## JSON output

The JSON document contains:

- schema and script versions;
- detected IPv4 and IPv6 addresses;
- registered country and ASN metadata;
- `primary`, `custom`, and `cdn` result arrays;
- per-country IPv4 and IPv6 consensus percentages.

HTTP failures remain individual service results (`Denied`, `Rate-limit`, `Server error`, or `N/A`) and do not invalidate successful checks.

The progress indicator is automatically disabled for JSON and redirected output.

## Network behavior

- `-IPv4` and `-IPv6` are mutually exclusive.
- Without either switch, both families are tested independently; an unavailable family is skipped.
- `-Interface` accepts the exact alias shown by `Get-NetAdapter`.
- A proxy without a URI scheme is interpreted as `socks5://`.
- Some services accept an IPv6 address only through IPv4 transport; this is handled per service.

## Development

Development dependencies are pinned separately from the dependency-free runtime:

```powershell
Install-PSResource Pester -Version 5.7.1 -Scope CurrentUser -TrustRepository
Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser -TrustRepository

Invoke-Pester ./tests
Invoke-ScriptAnalyzer ./ipregion.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

Live smoke test:

```powershell
pwsh ./ipregion.ps1 -Group Primary -IPv4 -Json
```

## Upstream and licensing

The original project and both referenced forks use the MIT License. The existing copyright and license text are retained in [LICENSE](LICENSE).

- Original: [vernette/ipregion](https://github.com/vernette/ipregion)
- Additional fixes and checks studied: [Davoyan/ipregion](https://github.com/Davoyan/ipregion)
