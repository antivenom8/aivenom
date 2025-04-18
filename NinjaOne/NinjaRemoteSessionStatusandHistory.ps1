<#
.SYNOPSIS
    This script is used to obtain the current Ninja Remote session status and history.

.DESCRIPTION
    Script looks for more than 1 NCStreamer process to be active and if so, looks at the logs generated by Ninja Remote to determine session start and session end.
    Custom fields are filled out to indicate start and end session times, as well as a checkbox to indicate active session. Additional custom field to record session history.

    # ---------------------------------------------------------------
    # Author: Mark Giordano
    # Date: 12/14/2024
    # Description: Gets Ninja Remote Session status to custom fields.
    # Updated: 1/17/2025 - Added Session History Collection
    # Updated: 4/18/2025 - Removed reliance on Agent Log. Added Tag option.
    # ---------------------------------------------------------------

.NOTES
    REQUIRED: Custom Fields
    Name: NinjaRemoteSessionStart
    Type: Text
    Name: NinjaRemoteSessionEnd
    Type: Text
    Name: NinjaRemoteSessionActive
    Type: Checkbox
    Name: NinjaRemoteSessionHistory
    Type: WYSIWYG

    OPTIONAL: Tags
    Make sure you've created a tag with your desired name.
    At the start of the script, after the fuctions, change $SetTag = '' to $SetTag = 'YourTagName', and script will
    set the device with the tag name you entered. It will remove it upon session end.

    The Session Start/End and Session Active can be added to the Device Grid to keep an eye on currently active sessions. 

    Designed to be ran as a Script Result Condition, the more frequent, the greater accuracy the script will have for active sessions. Recommended 1-5 minute intervals. 
    Exits 0, even if issues are found where it cannot collect the necessary info, this is to prevent alerts. This will simply run at the alloted frequency and keep the 
    custom fields updated.

    By default saves the most recent 30 session events. This can be adjusted by changing $SessionsToKeep.
#>

#### Functions ####
function ConvertTo-HTMLTable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [array]$Objects,
        [string]$NinjaInstance,
        [array]$ExcludedProperties = @('RowColor'),
        [string]$IncludeHeading
    )
    $BuildHTML = [System.Text.StringBuilder]::New()
    if ($IncludeHeading) {
        [void]$BuildHTML.Append("<h1 style='text-align: left'>$IncludeHeading</h1>")
    }
    
    [void]$BuildHTML.Append('<table>')
    [void]$BuildHTML.Append('<thead><tr>')

    $Objects[0].PSObject.Properties.Name | Where-Object { $_ -notin $ExcludedProperties } | 
    ForEach-Object { [void]$BuildHTML.Append("<th>$_</th>") }
    [void]$BuildHTML.Append('</tr></thead><tbody>')

    foreach ($Object in $Objects) {
        if ($Object.RowColor) { 
            [void]$BuildHTML.Append("<tr class='$($Object.RowColor)'>")
        }
        else {
            [void]$BuildHTML.Append("<tr>")
        }
        
        $FilteredProperties = $Object.PSObject.Properties.Name | Where-Object { $_ -notin $ExcludedProperties }
        foreach ($Property in $FilteredProperties) {
            $Value = $Object.$Property
            if ($Property -eq 'systemName') {
                $url = "https://$NinjaInstance/#/deviceDashboard/$($Object.Id)/overview"
                [void]$BuildHTML.Append("<td><a href='$url' target='_blank'>$Value</a></td>")
            }
            else {
                [void]$BuildHTML.Append("<td>$Value</td>")
            }
        }
        [void]$BuildHTML.Append('</tr>')
    }
    [void]$BuildHTML.Append('</tbody></table>')
    $FinalHTML = $BuildHTML.ToString()
    return $FinalHTML
}

#### End Functions ####

$SessionsToKeep = 30
$NRLogsLocation = "$env:systemroot\temp"
$SetTag = ''

$NRProcess = Get-Process | Where-Object { $_.Name -eq 'NCStreamer' }

if ($NRProcess.Count -gt 1) {

    $NRDetails = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ncstreamer.exe" } | 
    Sort-Object -Descending | 
    Select-Object Name, ProcessID, @{Name = "StartTime"; Expression = { ($_.CreationDate -as [datetime]).ToLocalTime() } } | 
    Sort-Object StartTime -Descending | Select-Object -First 1

    $NRStartTime = $NRDetails.StartTime

    if (!($NRStartTime)) {
        $NRStartTime = (Get-ChildItem "$($NRLogsLocation)" | 
            Where-Object { $_.Name -match "ncstreamer$($NRDetails.ProcessID)" }).CreationTime
    }

    try {
        New-Item "$NRLogsLocation\NRPID_$($NRDetails.ProcessID)" -Force -ErrorAction Stop
    }
    catch {
        Write-Host 'Unable to record the NR Remote Process ID for use in collecting the session end time. Exiting.'
        Write-Host "$($_.Exception.Message)"
        exit 0
    }

    Ninja-Property-Set NinjaRemoteSessionStart ($NRStartTime.ToString("yyyy-MM-dd HH:mm"))
    Ninja-Property-Set NinjaRemoteSessionActive 1
    Ninja-Property-Set NinjaRemoteSessionEnd ''

    if (!([string]::IsNullOrWhiteSpace($SetTag))) {
        Write-Host 'Setting NinjaTag'
        Set-NinjaTag "$SetTag"
    }

    exit 0
}

$CheckifStartTimeExists = Ninja-Property-Get NinjaRemoteSessionStart
$CheckifEndTimeExists = Ninja-Property-Get NinjaRemoteSessionEnd

if (!([string]::IsNullOrWhiteSpace($CheckifEndTimeExists)) -or ([string]::IsNullOrWhiteSpace($CheckifStartTimeExists))) {
    Write-Host 'End time already exists or there was no previously recorded start time. Exiting.'
    exit 0
}

$LastNRLog = Get-ChildItem $NRLogsLocation | 
Where-Object { ($_.Name -match 'ncstreamer') -and ($_.Name -notmatch 'ncstreamer_') } | 
Sort-Object LastWriteTime -Descending | Select-Object -First 1

$LastNRPID = Get-ChildItem $NRLogsLocation | Where-Object { $_.Name -match 'NRPID_' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

try {
    $NRPIDConfirmation = ($LastNRPID).Name.Substring(6)
}
catch {
    Write-Host 'Unable to determine previous NR Session PID. Exiting.'
    Write-Host "$($_.Exception.Message)"
    exit 0
}

if (!($LastNRLog -match $NRPIDConfirmation)) {
    Write-Host 'Unable to match last NR log process to Agent log process'
    exit 0
}

$NRSessionEndTime = $($LastNRLog.LastWriteTime).ToString("yyyy-MM-dd HH:mm")
$SessionDuration = $LastNRLog.LastWriteTime - $LastNRLog.CreationTime

$CompleteRecord = [PSCustomObject]@{
    'Session Start'    = $LastNRLog.CreationTime.ToString("yyyy-MM-dd HH:mm")
    'Session End'      = $NRSessionEndTime
    'Session Duration' = '{0:D2} Days | {1:D2} Hours | {2:D2} Minutes | {3:D2} Seconds' -f $SessionDuration.Days, $SessionDuration.Hours, $SessionDuration.Minutes, $SessionDuration.Seconds
}

$CheckHTML = Ninja-Property-Get NinjaRemoteSessionHistory
if (($CheckHTML | ConvertFrom-Json).html) {
    [xml]$HTMLtoXML = ($CheckHTML | ConvertFrom-Json).html
    $THeaders = $HTMLtoXML.SelectNodes("//thead/tr/th") | ForEach-Object { $_.InnerText }
    $TRows = $HTMLtoXML.SelectNodes("//tbody/tr")
    $HTMLtoObject = [System.Collections.Generic.List[object]]::New()
    foreach ($Row in $TRows) {
        $Value = $Row.td
        if ([string]::IsNullorWhiteSpace($Value)) { 
            continue 
        }
        $RowObject = [PSCustomObject]@{}
        for ($i = 0; $i -lt $THeaders.Count; $i++) {
            $RowObject | Add-Member -MemberType NoteProperty -Name $THeaders[$i] -Value $Value[$i]
        }
        $HTMLtoObject.Add($RowObject)
    }

    $HTMLtoObject.Add($CompleteRecord) 
    $HTMLtoObject = $HTMLtoObject | Sort-Object 'Session Start' -Descending

    if ($HTMLtoObject.Count -gt $SessionsToKeep) {
        $HTMLtoObject = $HTMLToObject[0..($HTMLToObject.Count - ($SessionsToKeep + 1))]
    }

    ##WYSIWYG fields have a limit of 200k characters. This will remove the oldest entry
    ## if character length is 190k or more, ensuring enough space for the most recent entry.
    if ($CheckHTML.Length -ge 190000) {
        Write-Host 'Removing oldest entry due to character limit...'
        $HTMLtoObject = $HTMLToObject[0..($HTMLToObject.Count - 2)]
    }

    $HTML = ConvertTo-HTMLTable $HTMLtoObject
    $HTML | Ninja-Property-Set-Piped NinjaRemoteSessionHistory
    Ninja-Property-Set NinjaRemoteSessionEnd $NRSessionEndTime
    Ninja-Property-Set NinjaRemoteSessionActive 0
}
else {
    $HTML = ConvertTo-HTMLTable $CompleteRecord
    $HTML | Ninja-Property-Set-Piped NinjaRemoteSessionHistory
    Ninja-Property-Set NinjaRemoteSessionEnd $NRSessionEndTime
    Ninja-Property-Set NinjaRemoteSessionActive 0
}

if (!([string]::IsNullOrWhiteSpace($SetTag))) {
    Write-Host 'Removing NinjaTag'
    Remove-NinjaTag "$SetTag"
}

Remove-Item $LastNRPID.FullName -Force

exit 0