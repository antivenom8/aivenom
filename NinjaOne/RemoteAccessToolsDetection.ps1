function Convert-ToHTMLCell {
    param ([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return ($Value -split "`n" | ForEach-Object { "<div>$_</div>" }) -join ''
}

function Convert-ToHTMLCellWithTooltip {
    param (
        [string[]]$Names,
        [string[]]$Tooltips
    )
    if (!$Names -or ($Names.Count -eq 1 -and [string]::IsNullOrWhiteSpace($Names[0]))) { return '' }
    $Result = for ($i = 0; $i -lt $Names.Count; $i++) {
        $Tooltip = if ($i -lt $Tooltips.Count) { $Tooltips[$i] } else { '' }
        "<div>$($Names[$i]) <a title='$Tooltip' style='text-decoration: none;'>⚠️</a></div>"
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
            $Finding.AppName
        }

        $RegCell = if ($Finding.RegistryVersion -or $Finding.RegistryPublisher -or $Finding.RegistryInstallSource -or $Finding.RegistryInstallLocation) {
            Convert-ToHTMLCellWithTooltip -Names @($Finding.RegistryDisplayName) -Tooltips @("Version: $($Finding.RegistryVersion)`nPublisher: $($Finding.RegistryPublisher)`nInstall Source: $($Finding.RegistryInstallSource)`nInstall Location: $($Finding.RegistryInstallLocation)")
        }
        else {
            $Finding.RegistryDisplayName
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
        if (!(Test-Path $LocalPath)) {
            Write-Host 'No local copy found, saving for future fallback...'
            $RemoteTools | ConvertTo-Json -Depth 10 | Set-Content $LocalPath
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

$ExtractedData = $Rats | ForEach-Object {
    $Name = $_.Name
    $EXEs = $_.Details.InstallationPaths | ForEach-Object {
        [regex]::Matches($_, '[\w.-]+\.exe') | ForEach-Object { $_.Value }
    } | Sort-Object -Unique
    $Domains = $_.Artifacts.Network.Domains
    $FileNames = $_.Details.PEMetadata.FileName
    $InstallPaths = $_.Details.InstallationPaths | Where-Object { $_ -match '^C:\\' }

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

$RunningProcesses = Get-Process | Where-Object {
    $_.Company -ne 'Microsoft Corporation' -and
    $_.Description -notmatch 'Microsoft|Windows'
} | Select-Object Name, Id, Path, Description, Company
$Services = Get-Service -ErrorAction SilentlyContinue
$DNSCache = Get-DnsClientCache | Select-Object -ExpandProperty Entry | Sort-Object -Unique
$InstalledSoftware = Get-InstalledSoftware
$ScheduledTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
$GroupedData = $ExtractedData | Group-Object -Property AppName


$Findings = foreach ($Group in $GroupedData) {
    $AppName = $Group.Name
    $MatchedReg = $InstalledSoftware | Where-Object { $_.DisplayName -match [regex]::Escape($AppName) }
    $MatchedReg = $MatchedReg | Where-Object {
        $RegDisplayName = $_.DisplayName
        !($Exclusions | Where-Object { $RegDisplayName -like "*$_*" })
    }
    $AllExes = $Group.Group.Executables | ForEach-Object { $_ } | Sort-Object -Unique
    $AllFileNames = $Group.Group.FileNames | ForEach-Object { $_ } | Sort-Object -Unique
    $AllDomains = $Group.Group.Domains | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique
    $AllInstallPaths = $Group.Group.InstallPaths | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique

    $AllProcessNames = @($AllExes) + @($AllFileNames) | 
    Where-Object { $_ } | 
    ForEach-Object { $_ -replace '\.exe$', '' } | 
    Sort-Object -Unique

    $MatchedProcess = $RunningProcesses | Where-Object { $_.Name -in $AllProcessNames }
    $MatchedProcess = $MatchedProcess | Where-Object {
        $ProcessPath = $_.Path
        !($Exclusions | Where-Object { $ProcessPath -like "*$_*" })
    }
    $MatchedService = $Services | Where-Object {
        $_.Name -like "*$AppName*" -or $_.DisplayName -like "*$AppName*"
    } | ForEach-Object {
        $Service = $_
        $ServicePath = (Get-CimInstance Win32_Service -Filter "Name='$($Service.Name)'" -ErrorAction SilentlyContinue).PathName -replace '"', '' -replace ' -.*$', ''
        
        if ($ServicePath -and (Test-Path $ServicePath -ErrorAction SilentlyContinue)) {
            $VersionInfo = (Get-Item $ServicePath -ErrorAction SilentlyContinue).VersionInfo
            $IsMicrosoft = $VersionInfo.CompanyName -match 'Microsoft' -or
            $VersionInfo.ProductName -match 'Microsoft' -or
            $VersionInfo.FileDescription -match 'Microsoft'
            if (!$IsMicrosoft) {
                $Service | Add-Member -NotePropertyName ServicePath -NotePropertyValue $ServicePath -PassThru
            }
        }
        else {
            $Service | Add-Member -NotePropertyName ServicePath -NotePropertyValue $ServicePath -PassThru
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
    $MatchedPaths = $AllInstallPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Where-Object {
        $Item = Get-Item $_ -ErrorAction SilentlyContinue
        if ($Item -and !$Item.PSIsContainer) {
            $Item.VersionInfo.ProductName -notmatch 'Microsoft' -and
            $Item.VersionInfo.CompanyName -notmatch 'Microsoft'
        }
        else {
            $true
        }
    }

    $MatchedTasks = $ScheduledTasks | Where-Object {
        $Task = $_
        $TaskAction = $Task.Actions | Where-Object { $_.Execute -match [regex]::Escape($AppName) }
        $Task.TaskName -like "*$AppName*" -or 
        $TaskAction
    } | Where-Object {
        $_.Author -notmatch 'Microsoft'
    } | Where-Object {
        $TaskPath = $_.Actions.Execute -replace '"', '' -replace ' .*$', ''
        if ($TaskPath -and (Test-Path $TaskPath -ErrorAction SilentlyContinue)) {
            $VersionInfo = (Get-Item $TaskPath -ErrorAction SilentlyContinue).VersionInfo
            $VersionInfo.CompanyName -notmatch 'Microsoft' -and
            $VersionInfo.ProductName -notmatch 'Microsoft' -and
            $VersionInfo.FileDescription -notmatch 'Microsoft'
        }
        else {
            $true
        }
    }

    $MatchedTaskPaths = ($MatchedTasks | ForEach-Object {
            "Task Path: $($_.Actions.Execute -replace '"', '' -replace ' .*$', '')"
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