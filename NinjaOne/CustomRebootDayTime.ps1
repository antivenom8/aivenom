<#
.SYNOPSIS
    This script is used to do a flexible custom reboot schedule within a 30 minute time window based off custom fields.

.DESCRIPTION
    Use this script as a Script Result Condition. It will look to a custom field to pull its reoccurance of when it should trigger. 

    # ---------------------------------------------------------------
    # Author: Mark Giordano
    # Date: 2/25/2025
    # ---------------------------------------------------------------

.NOTES
    Custom Fields Required:
    Name: RebootDayTime
    Type: Text

    Variables
    Name: TimeWindow
    Type: Int
    Details: Defaults to 30. You can adjust the window, and therefore change how often the condition needs
    to check. Should be in minutes.

    The custom field should be filled out in the following way: Number|Day|Military Time. 
    As an example: 3|Saturday|20:00 - This would tell the script it's allowed to reboot the
    device on the 3rd Saturday of every month between 20:00 (8PM) and 20:30 (8:30:PM). 

    UPDATE: Added Weekly and Daily options. 
    Weekly: Format remains the same, with the exception of the first part must state Weekly.
    Example: Weekly|Friday|20:00 - This would indicate a reboot every Friday between 20:00 (8PM) 
    and 20:30 (8:30:PM)

    Daily: Custom field must still have 3 parts, first part stating Daily, but the middle part is essentially ignored, so
    it can be as simple as leaving it as just blank. 
    Example 1: Daily|Friday|20:00 - This would indicate a reboot every day between 20:00 (8PM) 
    and 20:30 (8:30:PM). The Day here is ignored since it's set to Daily.
    Example 2: Daily||20:00 - This would indicate a reboot every day between 20:00 (8PM) 
    and 20:30 (8:30:PM). Again, the middle part is essentially ignored.

    In the example above, the Script Result Condition should be set to check every 30 minutes.
    This is to ensure it will be able to evaluate the custom field within the alloted time slot
    of 30 minutes. You can adjust the window, and therefore change how often the condition needs
    to check. This can be done by adjusting the $TimeWindow variable. If for example, changed to
    60, then you can adjust the condition to check every 60 minutes. This also means your actual
    reboot window would be from the time you set in the custom field + 60 minutes. 20:00 becomes
    8PM - 9PM for example. 
    
#>

$TimeWindow = 30
#$RebootDayTime = Ninja-Property-Get RebootDayTime
$RebootDayTime = '2|Friday|23:00'

# Function to determine the nth occurrence of a given weekday in the specified month/year
function Get-NthOccurrence {
    param (
        [int]$Year,
        [int]$Month,
        [string]$Weekday,
        [int]$Occurrence
    )

    $Occurrences = [System.Collections.Generic.List[object]]::New()
    $DaysInMonth = [DateTime]::DaysInMonth($Year, $Month)
    for ($Day = 1; $Day -le $DaysInMonth; $Day++) {
        $DateObj = Get-Date -Year $Year -Month $Month -Day $Day
        if ($DateObj.DayOfWeek.ToString() -eq $Weekday) {
            $Occurrences.Add($DateObj.Date)
        }
    }
    if ($Occurrence -le $Occurrences.Count) {
        return $Occurrences[$Occurrence - 1]
    }
    else {
        return $null
    }
}

if ([string]::IsNullOrWhiteSpace($RebootDayTime)) {
    Write-Host 'Error: No reboot day/time found.'
    exit 0
}

$Split = $RebootDayTime.Split('|')
if ($Split.Count -ne 3) {
    Write-Host "Error: Input must have exactly three parts separated by '|'."
    exit 0
}

$RebootOccurrence = $Split[0].Trim()
$RebootDay = $Split[1].Trim()
$RebootTime = $Split[2].Trim()

# Get current date and time
$Now = Get-Date
$CurrentYear = $Now.Year
$CurrentMonth = $Now.Month

# Validate the day of week
$ValidDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

if (!($RebootOccurrence -eq 'Daily')) {
    if ([string]::IsNullOrWhiteSpace($RebootDay)) {
        Write-Host 'You must specify a day of the week when using weekly or nth occurence. Exiting.'
        exit 0
    }

    if ($ValidDays -notcontains $RebootDay) {
        Write-Host "Error: $RebootDay is not a valid day of the week."
        Write-Host "Valid entires are: $($ValidDays -join ',' | Out-String)"
        exit 0
    }
}

switch ($RebootOccurrence) {
    { $_ -eq 'Weekly' } {
        if ($Now.DayofWeek -ne "$RebootDay") {
            Write-Host "Today is not the scheduled reboot day: $RebootDay"
            exit 0
        } 
    }
    { $_ -eq 'Daily' } {
        break
    }
    { $_ -match '[0-9]' } {
        # Validate the occurrence as an integer
        if (!([int]::TryParse($RebootOccurrence, [ref]$null))) {
            Write-Host 'Error: The first part must be an integer representing the occurrence (e.g. 2).'
            exit 0
        }
        
        $RebootOccurrence = [int]$RebootOccurrence
        
        if ($RebootOccurrence -le 0) {
            Write-Host 'Error: The occurrence must be a positive integer.'
            exit 0
        }
        
        # Get the reoccurance
        $NthOccurrence = Get-NthOccurrence -Year $CurrentYear -Month $CurrentMonth -Weekday $RebootDay -Occurrence $RebootOccurrence
        
        if (!($NthOccurrence)) {
            Write-Host "Error: There are not $RebootOccurrence $($RebootDay)s in this month."
            exit 0
        }
        
        # Check if today is the nth occurrence of the specified weekday
        if ($Now.Date -ne $NthOccurrence) {
            Write-Host "Today is not the $RebootOccurrence $RebootDay ($($NthOccurrence.ToShortDateString())) of this month. Exiting."
            exit 0
        }
    }
    Default {
        WRite-Host 'Unable to determine the reboot occurrence. Exiting.'
        exit 0
    }
}



# if (!($RebootOccurance -match 'Weekly|Daily')) {
#     # Validate the occurrence as an integer
#     if (!([int]::TryParse($RebootOccurance, [ref]$null))) {
#         Write-Host 'Error: The first part must be an integer representing the occurrence (e.g. 2).'
#         exit 0
#     }

#     [int]$Nth = $RebootOccurance

#     if ($Nth -le 0) {
#         Write-Host 'Error: The occurrence must be a positive integer.'
#         exit 0
#     }

#     # Get the reoccurance
#     $NthOccurrence = Get-NthOccurrence -Year $CurrentYear -Month $CurrentMonth -Weekday $RebootDay -Occurrence $RebootOccurance

#     if (!($NthOccurrence)) {
#         Write-Host "Error: There are not $Nth $($RebootDay)s in this month."
#         exit 0
#     }

#     # Check if today is the nth occurrence of the specified weekday
#     if ($Now.Date -ne $NthOccurrence) {
#         Write-Host "Today is not the $Nth $RebootDay ($($NthOccurrence.ToShortDateString())). Exiting."
#         exit 0
#     }
# }
# else {
#     if ($Now.DayofWeek -ne "$RebootDay") {
#         Write-Host "Today is not the scheduled reboot day: $RebootDay"
#         exit 0
#     }
# }

# Validate the time (HH:MM in 24-hour format)
$TimePattern = '^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$'
if ($RebootTime -notmatch $TimePattern) {
    Write-Host 'Error: Time must be in 24-hour format (HH:MM), including leading zeros if necessary.'
    exit 0
}

$TimeSplit = $RebootTime.Split(':')
[int]$ScheduledHour = $TimeSplit[0]
[int]$ScheduledMinute = $TimeSplit[1]

# Build the scheduled DateTime from today's date and the provided time
$ScheduledDateTime = Get-Date -Year $CurrentYear -Month $CurrentMonth -Day $Now.Day -Hour $ScheduledHour -Minute $ScheduledMinute -Second 0
$EndTime = $ScheduledDateTime.AddMinutes($TimeWindow).ToString('HH:mm')

# Calculate the difference in minutes between now and the scheduled time
$TimeDifference = ($Now - $ScheduledDateTime).TotalMinutes

# Check if current time is within the scheduled window, TimeWindow. (0 to specified minutes after set time)
if (($TimeDifference -ge 0) -and ($TimeDifference -le $TimeWindow)) {
    #Check if the device already rebooted within the allotted time. 
    $LastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $Uptime = [math]::Round(((Get-Date) - $LastBoot).TotalMinutes, 0)

    if ($Uptime -le $TimeWindow) {
        Write-Host 'Already rebooted within the alloted time window. Exiting.'
        exit 0
    }

    Write-Host 'Conditions met. Rebooting device.'
    Restart-Computer -Force
}
else {
    Write-Host "Current time is not within the scheduled window ($RebootTime - $EndTime). Exiting."
    exit 0
}