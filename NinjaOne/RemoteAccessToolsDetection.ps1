<#
.SYNOPSIS
This script is used to detect installed or active Remote Access Tools (RMM/RATs) on an endpoint.

.DESCRIPTION
Script pulls the LOLRMM tool database from lolrmm.io and keeps a local cached copy for fallback. 
It parses each tool's known executables, domains, file names, and install paths then scans the device 
across multiple vectors: running processes, services, DNS client cache, 
installed software (registry uninstall keys under HKLM and every user hive, including unloaded profiles)
and scheduled tasks. Microsoft-signed items are filtered out. Each detected tool is assigned a confidence
score based on how many vectors matched, and results are written to custom fields as both a plain-text 
summary and a color-coded WYSIWYG HTML table.

# ---------------------------------------------------------------
# Author: Mark Giordano
# Date: June 29th, 2026
# Description: Detects Remote Access / RMM tools and reports findings to custom fields.
# ---------------------------------------------------------------

.NOTES
### Requried Custom Fields ###
Name: RemoteAccessTools
Type: WYSIWYG

Name: DetectedRATs
Type: Text

### Optional Custom Fields ###
Name: RATExclusions
Type: Text
Comma-separated list of app/registry names to exclude from findings. Read at runtime and combined with the DefaultRATExclusions script variable.

### Required Script Variables ###
ITToolsPath
Type: Text
Directory path used to store the local rmm_tools.json fallback cache. Referenced as $env:ITToolsPath.

### Optional Script Variables ###
DefaultRATExclusions
Type: Text
Comma-separated list of default exclusions applied on every run. Referenced as $env:DefaultRATExclusions.

Confidence scoring: 
Matched Process +3
Registry (installed software) +3
Process description matches app name +2
Install path present on disk +2
DNS cache hit +2
Scheduled task +2
Service +1.

HTML row coloring is driven by the confidence score:
8 or higher = danger
5-7 = warning
3-4 = other
below 3 = unknown

Pulls the latest tool database. If the remote pull fails, it falls back to the locally cached json.
If neither source is available, the script exits 1. If no tools are found, the RemoteAccessTools and
DetectedRATs custom fields are cleared. Exits 0 on completion.
#>

function ConvertTo-HtmlSafe {
    param ([string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}
function Convert-ToHTMLCell {
    param ([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return ($Value -split "`n" | ForEach-Object { "<div>$(ConvertTo-HtmlSafe $_)</div>" }) -join ''
}

function Convert-ToHTMLCellWithTooltip {
    param (
        [string[]]$Names,
        [string[]]$Tooltips
    )
    if (!$Names -or ($Names.Count -eq 1 -and [string]::IsNullOrWhiteSpace($Names[0]))) { return '' }
    $Result = for ($i = 0; $i -lt $Names.Count; $i++) {
        $Tooltip = if ($i -lt $Tooltips.Count) { $Tooltips[$i] } else { '' }
        "<div>$(ConvertTo-HtmlSafe $Names[$i]) <a title='$(ConvertTo-HtmlSafe $Tooltip)' style='text-decoration: none;'>⚠️</a></div>"
    }
    return $Result -join ''
}
function ConvertTo-NinjaHTML {
    param (
        [Parameter(Mandatory)]
        [array]$Findings
    )

    $HTML = @"
<table>
  <thead>
    <tr>
    <th style="white-space: nowrap;">App Name</th>
    <th style="white-space: nowrap;">Score</th>
    <th style="white-space: nowrap;">Registry DisplayName</th>
    <th style="white-space: nowrap;">Processes</th>
    <th>Service Name</th>
    <th style="white-space: nowrap;">Service DisplayName</th>
    <th>DNS Cache</th>
    <th style="white-space: nowrap;">Scheduled Tasks</th>
    </tr>
  </thead>
  <tbody>
"@

    foreach ($Finding in $Findings) {
        $RowClass = switch ($true) {
            { $Finding.ConfidenceScore -ge 8 } { 'danger'; break }
            { $Finding.ConfidenceScore -ge 5 } { 'warning'; break }
            { $Finding.ConfidenceScore -ge 3 } { 'other'; break }
            default { 'unknown' }
        }

        $AppNameCell = if ($Finding.PathMatches) {
            Convert-ToHTMLCellWithTooltip -Names @($Finding.AppName) -Tooltips @($Finding.PathMatches)
        }
        else {
            ConvertTo-HtmlSafe $Finding.AppName
        }

        $RegCell = if ($Finding.RegistryVersion -or $Finding.RegistryPublisher -or $Finding.RegistryInstallSource -or $Finding.RegistryInstallLocation) {
            Convert-ToHTMLCellWithTooltip -Names @($Finding.RegistryDisplayName) -Tooltips @("Version: $($Finding.RegistryVersion)`nPublisher: $($Finding.RegistryPublisher)`nInstall Source: $($Finding.RegistryInstallSource)`nInstall Location: $($Finding.RegistryInstallLocation)")
        }
        else {
            ConvertTo-HtmlSafe $Finding.RegistryDisplayName
        }

        $HTML += @"
    <tr class="$RowClass">
    <td style="white-space: nowrap;">$AppNameCell</td>
    <td style="white-space: nowrap;">$($Finding.ConfidenceScore)</td>
    <td>$RegCell</td>
    <td>$(Convert-ToHTMLCellWithTooltip -Names ($Finding.ProcessNames -split "`n") -Tooltips ($Finding.ProcessPaths -split "`n"))</td>
    <td>$(Convert-ToHTMLCellWithTooltip -Names ($Finding.ServiceNames -split "`n") -Tooltips ($Finding.ServicePaths -split "`n"))</td>
    <td>$(Convert-ToHTMLCell $Finding.ServiceDisplayNames)</td>
    <td>$(Convert-ToHTMLCell $Finding.DNSMatches)</td>
    <td>$(Convert-ToHTMLCellWithTooltip -Names ($Finding.ScheduledTasks -split "`n") -Tooltips ($Finding.ScheduledTaskPaths -split "`n"))</td>
    </tr>
"@
    }

    $HTML += @"
  </tbody>
</table>
"@

    return $HTML
}

function Get-InstalledSoftware {
    $Apps = [System.Collections.Generic.List[object]]::New()
    $32BitPath = "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $64BitPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"

    $Apps.AddRange(@(Get-ItemProperty "HKLM:\$32BitPath" -ErrorAction SilentlyContinue))
    $Apps.AddRange(@(Get-ItemProperty "HKLM:\$64BitPath" -ErrorAction SilentlyContinue))

    $AllProfiles = Get-CimInstance Win32_UserProfile | 
    Select-Object LocalPath, SID, Loaded, Special | 
    Where-Object { $_.SID -match "^S-1-5-21-|^S-1-12-1-" }

    $AllProfiles | Where-Object { $_.Loaded } | ForEach-Object {
        $Apps.AddRange(@(Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$32BitPath" -ErrorAction SilentlyContinue))
        $Apps.AddRange(@(Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$64BitPath" -ErrorAction SilentlyContinue))
    }

    $AllProfiles | Where-Object { !$_.Loaded } | ForEach-Object {
        $Hive = "$($_.LocalPath)\NTUSER.DAT"
        if (Test-Path $Hive) {
            REG LOAD HKU\temp $Hive 2>&1>$null
            $Apps.AddRange(@(Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$32BitPath" -ErrorAction SilentlyContinue))
            $Apps.AddRange(@(Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$64BitPath" -ErrorAction SilentlyContinue))
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            REG UNLOAD HKU\temp 2>&1>$null
        }
    }

    return $Apps | Where-Object { $_.DisplayName }
}

function Get-LOLRMMData {
    $ToolsUrl = 'https://lolrmm.io/api/rmm_tools.json'
    $LocalPath = "$ITToolsPath\rmm_tools.json"

    Write-Host 'Collecting tool info...'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12'
        $RemoteTools = Invoke-RestMethod -Uri $ToolsUrl -UseBasicParsing -ErrorAction Stop
        try {
            $RemoteTools | ConvertTo-Json -Depth 10 | Set-Content $LocalPath -ErrorAction Stop
            Write-Host 'Updated local fallback copy.'
        }
        catch {
            Write-Host "Could not update local fallback copy: $_"
        }
        Write-Host 'Successfully collected tool data from remote.'
        return $RemoteTools
    }
    catch {
        Write-Host "Failed to pull tool database from URL: $_"
        Write-Host 'Falling back to local json file...'
    }

    try {
        if (!(Test-Path $LocalPath)) {
            Write-Host "Local file not found at $LocalPath"
            exit 1
        }
        $RemoteTools = Get-Content $LocalPath -Raw | ConvertFrom-Json
        Write-Host 'Successfully loaded tool data from local file.'
        return $RemoteTools
    }
    catch {
        Write-Host "Failed to load tool data from both remote and local: $_"
        exit 1
    }
}

$ScriptHosts = 'powershell', 'pwsh', 'cmd', 'wscript', 'cscript', 'mshta', 'rundll32', 'regsvr32', 'conhost'

function Get-ExecutablePath {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $Expanded = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $Path = if ($Expanded -match '^"([^"]+)"') { $Matches[1] }
    elseif ($Expanded -match '^(.+?\.(exe|com|bat|cmd))(\s|$)') { $Matches[1] }
    else { ($Expanded -split '\s+')[0] }

    # IsPathRooted throws on invalid path chars in Windows PowerShell 5.1; treat as rooted so we skip Get-Command
    $IsRooted = try { [IO.Path]::IsPathRooted($Path) } catch { $true }
    if (!$IsRooted) {
        # Bare names like "powershell.exe" in task actions
        $Resolved = (Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if ($Resolved) { $Path = $Resolved }
    }
    return $Path
}

function Test-MicrosoftSigned {
    param([string]$Path)
    if (!$Path -or !(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $Sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($Sig.Status -eq 'Valid' -and $Sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}

$ITToolsPath = "$env:ITToolsPath"

if (!(Test-Path $ITToolsPath)) {
    Write-Host 'IT Tools path not found. Creating...'
    New-Item "$ITToolsPath" -ItemType Directory -Force
}

$Exclusions = [System.Collections.Generic.List[string]]::New()
if (![string]::IsNullOrWhiteSpace($env:DefaultRATExclusions)) { $Exclusions.AddRange([string[]]($env:DefaultRATExclusions.Split(',').Trim())) }
$ExclusionsFromCF = Get-NinjaProperty RATExclusions
if (![string]::IsNullOrWhiteSpace($ExclusionsFromCF)) { $Exclusions.AddRange([string[]]($ExclusionsFromCF.Split(',').Trim())) }

$Rats = Get-LOLRMMData

Write-Host 'Extracting and parsing data...'

$InstallRoots = @($env:SystemDrive, $env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, $env:ProgramData) |
Where-Object { $_ } | Sort-Object -Unique
$ProfilePaths = [System.Collections.Generic.List[string]]::new()
$ProfilePaths.AddRange([string[]]@(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -match '^S-1-5-21-|^S-1-12-1-' } |
        Select-Object -ExpandProperty LocalPath))

$ExtractedData = $Rats | ForEach-Object {
    $Name = $_.Name
    $EXEs = $_.Details.InstallationPaths | ForEach-Object {
        [regex]::Matches($_, '[\w.-]+\.exe') | ForEach-Object { $_.Value }
    } | Sort-Object -Unique
    $Domains = $_.Artifacts.Network.Domains
    $FileNames = $_.Details.PEMetadata.FileName
    $InstallPaths = foreach ($Path in $_.Details.InstallationPaths) {
        if ($Path -match '^C:\\') { $Path }
        elseif ($Path -match '^\*(\\AppData\\.+)$') {
            $Suffix = $Matches[1]
            foreach ($ProfilePath in $ProfilePaths) { "$ProfilePath$Suffix" }
        }
        elseif ($Path -match '^\*Users\\\*(\\.+)$') {
            # "*Users\*\..." - same as above, written without the leading backslash
            $Suffix = $Matches[1]
            foreach ($ProfilePath in $ProfilePaths) { "$ProfilePath$Suffix" }
        }
        elseif ($Path -match '^\*\\([^*].+)$') {
            # Unanchored "*\Vendor\..." or "*\ProgramData\..." - try the common install roots
            $Suffix = $Matches[1]
            foreach ($Root in $InstallRoots) { "$Root\$Suffix" }
        }
        # Bare filenames: already covered by process-name matching
    }

    [PSCustomObject]@{
        AppName      = $Name
        Executables  = $EXEs
        Domains      = $Domains
        FileNames    = $FileNames
        InstallPaths = $InstallPaths
    }
}

Write-Host 'Data parsed. Now performing various searches for matching applications.'
Write-Host 'This could take a few minutes...'

$CimPaths = @{}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object { $CimPaths[[int]$_.ProcessId] = $_.ExecutablePath }

$RunningProcesses = Get-Process | Select-Object Name, Id, Description, Company,
@{ N = 'Path'; E = { if ($_.Path) { $_.Path } else { $CimPaths[$_.Id] } } } |
Where-Object { $_.Path }   # no readable path = protected system process
$Services = Get-Service -ErrorAction SilentlyContinue
$DNSCache = Get-DnsClientCache | Select-Object -ExpandProperty Entry | Sort-Object -Unique
$InstalledSoftware = Get-InstalledSoftware
$ScheduledTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
$GroupedData = $ExtractedData | Group-Object -Property AppName

$ServicePathMap = @{}
Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object { $ServicePathMap[$_.Name] = $_.PathName }

$Findings = foreach ($Group in $GroupedData) {
    $AppName = $Group.Name
    $MatchedReg = $InstalledSoftware | Where-Object { $_.DisplayName -match [regex]::Escape($AppName) }
    $MatchedReg = $MatchedReg | Where-Object {
        # Check name, publisher and install location so e.g. "steamapps" can exclude a game without killing the RAT detection
        $Reg = $_
        !($Exclusions | Where-Object {
                $Reg.DisplayName -like "*$_*" -or
                $Reg.Publisher -like "*$_*" -or
                $Reg.InstallLocation -like "*$_*"
            })
    }
    $AllExes = $Group.Group.Executables | ForEach-Object { $_ } | Sort-Object -Unique
    $AllFileNames = $Group.Group.FileNames | ForEach-Object { $_ } | Sort-Object -Unique
    $AllDomains = $Group.Group.Domains | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique
    $AllInstallPaths = $Group.Group.InstallPaths | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique

    $AllProcessNames = @($AllExes) + @($AllFileNames) | 
    Where-Object { $_ } | 
    ForEach-Object { $_ -replace '\.exe$', '' } | 
    Sort-Object -Unique

    $ExactNames = $AllProcessNames | Where-Object { $_ -notmatch '[*?]' }
    # Require 4+ literal chars so a pattern like "*" can't match every process
    $NamePatterns = $AllProcessNames | Where-Object { $_ -match '[*?]' -and ($_ -replace '[*?]', '').Length -ge 4 }

    $MatchedProcess = $RunningProcesses | Where-Object {
        $ProcName = $_.Name
        ($ProcName -in $ExactNames -or ($NamePatterns | Where-Object { $ProcName -like $_ })) -and
        !(Test-MicrosoftSigned $_.Path)
    }
    $MatchedProcess = $MatchedProcess | Where-Object {
        $ProcessPath = $_.Path
        !($Exclusions | Where-Object { $ProcessPath -like "*$_*" })
    }

    $MatchedService = $Services | Where-Object {
        $_.Name -like "*$AppName*" -or $_.DisplayName -like "*$AppName*"
    } | ForEach-Object {
        $Service = $_
        $BinaryToCheck = Get-ExecutablePath $ServicePathMap[$Service.Name]
    
        # svchost-hosted: the code that runs is the ServiceDll, not svchost
        if ($BinaryToCheck -match '\\svchost\.exe$') {
            $Dll = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($Service.Name)\Parameters" -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
            if ($Dll) { $BinaryToCheck = [Environment]::ExpandEnvironmentVariables($Dll) }
        }
    
        if (!(Test-MicrosoftSigned $BinaryToCheck)) {
            $Service | Add-Member -NotePropertyName ServicePath -NotePropertyValue $BinaryToCheck -PassThru -Force
        }
    }

    $MatchedService = $MatchedService | Where-Object {
        $ServiceDisplayName = $_.DisplayName
        !($Exclusions | Where-Object { $ServiceDisplayName -like "*$_*" })
    }

    $MatchedServicePaths = ($MatchedService.ServicePath | Where-Object { $_ } | ForEach-Object { "Service Path: $_" }) -join "`n"

    $MatchedDNS = $DNSCache | Where-Object { 
        $CacheEntry = $_
        $AllDomains | Where-Object { $CacheEntry -like "*$_*" }
    }
    $MatchedPaths = $AllInstallPaths |
    ForEach-Object { Get-Item -Path $_ -Force -ErrorAction SilentlyContinue } |
    Where-Object { $_.PSIsContainer -or !(Test-MicrosoftSigned $_.FullName) } |
    Select-Object -ExpandProperty FullName |
    Where-Object {
        $MatchedPath = $_
        !($Exclusions | Where-Object { $MatchedPath -like "*$_*" })
    }

    $MatchedTasks = $ScheduledTasks | Where-Object {
        $Task = $_
        $Task.TaskName -like "*$AppName*" -or
        ($Task.Actions | Where-Object { $_.Execute -match [regex]::Escape($AppName) })
    } | Where-Object {
        $Exes = @($_.Actions | Where-Object { $_.Execute } | ForEach-Object { Get-ExecutablePath $_.Execute })
        if (!$Exes) { return $true }   # COM-handler-only task: can't verify, keep (same as before)
        # Keep if any action runs a non-Microsoft binary, or a script host
        [bool]($Exes | Where-Object {
                !(Test-MicrosoftSigned $_) -or
                [IO.Path]::GetFileNameWithoutExtension($_) -in $ScriptHosts
            })
    } | Where-Object {
        $TaskText = "$($_.TaskPath)$($_.TaskName) $(@($_.Actions.Execute) -join ' ')"
        !($Exclusions | Where-Object { $TaskText -like "*$_*" })
    }
    
    $MatchedTaskPaths = ($MatchedTasks | ForEach-Object {
            $_.Actions | Where-Object { $_.Execute } | ForEach-Object { "Task Path: $(Get-ExecutablePath $_.Execute)" }
        }) -join "`n"

    $ConfidenceScore = 0
    if ($MatchedProcess) { $ConfidenceScore += 3 }
    if ($MatchedProcess -and ($MatchedProcess | Where-Object { $_.Description -match [regex]::Escape($AppName) })) { 
        $ConfidenceScore += 2 
    }
    if ($MatchedReg) { $ConfidenceScore += 3 }
    if ($MatchedPaths) { $ConfidenceScore += 2 }
    if ($MatchedDNS) { $ConfidenceScore += 2 }
    if ($MatchedService) { $ConfidenceScore += 1 }
    if ($MatchedTasks) { $ConfidenceScore += 2 }

    if ($ConfidenceScore -gt 0) {
        if ($MatchedReg) {
            foreach ($Reg in $MatchedReg) {
                [PSCustomObject]@{
                    AppName                 = $AppName
                    ConfidenceScore         = $ConfidenceScore
                    RegistryDisplayName     = $Reg.DisplayName
                    RegistryInstallLocation = $Reg.InstallLocation
                    RegistryInstallSource   = $Reg.InstallSource
                    ProcessNames            = $MatchedProcess.Name -join "`n"
                    ProcessIDs              = $MatchedProcess.Id -join ', '
                    ProcessPaths            = ($MatchedProcess.Path | Where-Object { $_ } | ForEach-Object { "Process Path: $_" }) -join "`n"
                    ServiceDisplayNames     = $MatchedService.DisplayName -join "`n"
                    ServiceNames            = $MatchedService.Name -join "`n"
                    ServicePaths            = $MatchedServicePaths
                    PathMatches             = ($MatchedPaths | ForEach-Object { "Install Path: $_" }) -join "`n"
                    RegistryVersion         = $Reg.DisplayVersion
                    RegistryPublisher       = $Reg.Publisher
                    DNSMatches              = $MatchedDNS -join "`n"
                    ScheduledTasks          = ($MatchedTasks.TaskName | Where-Object { $_ }) -join "`n"
                    ScheduledTaskPaths      = $MatchedTaskPaths
                }
            }
        }
        else {
            [PSCustomObject]@{
                AppName                 = $AppName
                ConfidenceScore         = $ConfidenceScore
                RegistryDisplayName     = $null
                RegistryInstallLocation = $null
                RegistryInstallSource   = $null
                ProcessNames            = $MatchedProcess.Name -join "`n"
                ProcessIDs              = $MatchedProcess.Id -join ', '
                ProcessPaths            = ($MatchedProcess.Path | Where-Object { $_ } | ForEach-Object { "Process Path: $_" }) -join "`n"
                ServiceDisplayNames     = $MatchedService.DisplayName -join "`n"
                ServiceNames            = $MatchedService.Name -join "`n"
                ServicePaths            = $MatchedServicePaths
                PathMatches             = ($MatchedPaths | ForEach-Object { "Install Path: $_" }) -join "`n"
                RegistryVersion         = $null
                RegistryPublisher       = $null
                DNSMatches              = $MatchedDNS -join "`n"
                ScheduledTasks          = ($MatchedTasks.TaskName | Where-Object { $_ }) -join "`n"
                ScheduledTaskPaths      = $MatchedTaskPaths
            }
        }
    }
}

$FilteredFindings = $Findings | Where-Object {
    $AppName = $_.AppName
    $RegName = $_.RegistryDisplayName

    $Excluded = $Exclusions | Where-Object {
        $AppName -like "*$_*" -or $RegName -like "*$_*"
    }

    !$Excluded
}

if (!($FilteredFindings)) {
    Write-Host 'No Remote Access Tools found.'
    Ninja-Property-Clear RemoteAccessTools
    Ninja-Property-Clear DetectedRATs
    exit 0
}

$SortedFindings = $FilteredFindings | Sort-Object ConfidenceScore -Desc
Write-Host 'Remote Access Tools Found:'
Write-Host ($SortedFindings | Format-List | Out-String)
$ToTextCF = ($SortedFindings | ForEach-Object { "$($_.AppName) ($($_.ConfidenceScore))" }) -join ' | '
Set-NinjaProperty DetectedRATs $ToTextCF
$HTML = ConvertTo-NinjaHTML -Findings $SortedFindings
$HTML | Set-NinjaProperty RemoteAccessTools
exit 0