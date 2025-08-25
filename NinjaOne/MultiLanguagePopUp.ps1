<#
.SYNOPSIS
    Reboot reminder that will display in the language of the OS.

.DESCRIPTION
    Reboot reminder that will display in the language of the OS. Uses Google's unoffical translate API.

    # ---------------------------------------------------------------
    # Author: Mark Giordano
    # Date: 8/20/2025
    # ---------------------------------------------------------------

.NOTES
    Script MUST be set to Run as Current Logged On User, not system.

    Script Form Variables

    Name: Threshold
    Type: Int
    Set the # of days the device needs to be up by to determine if a reboot is needed.

    Name: Language
    Type: String/Text
    This allows you to enter the 2 letter set to indicate the language the pop up should display in.
    This will override the detection part of the script so it doesn't use the detected languade from OS.
    https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes

    Name: Title
    Type: String/Text
    Set the text of the popup box title. If left blank, will use the defaults in the script.

    Name: Message
    Type: String/Text
    Set the text of the message area. If left blank, will use the defaults in the script. 

    Name: Reboot Button
    Type: String/Text
    Set the text of the reboot button. If left blank, will use the defaults in the script.

    Name: Cancel Button
    Type: String/Text
    Set the text of the cancel button. If left blank, will use the defaults in the script.
    
#>


function Get-Translation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Original,
        [Parameter(Mandatory = $true)]
        [string]$TargetLanguage
    )

    $Encode = [uri]::EscapeDataString($Original)
    $uri = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$TargetLanguage&dt=t&q=$Encode"
    try {
        $Response = Invoke-RestMethod $Uri
        return ($Response[0] | ForEach-Object { $_[0] }) -join ''
    }
    catch {
        #In case translation fails, returning the original English text
        return $Original 
    }
}

# Script should run as current logged on user, so this checks for system and exits if true.
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)) {
    Write-Host 'Script is currently running as system, but needs to be ran as current logged on user. Exiting.'
    exit 0
}


$Threshold = [int]$env:Threshold
if (!($Threshold)) {
    Write-Host 'No threshold entered. Cannot continue.'
    exit 0
}

Add-Type -AssemblyName PresentationCore, PresentationFramework | Out-Null

$DaysSinceLastReboot = (New-TimeSpan -Start ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime) -End ([DateTime]::Now)).Days

# Exiting immediately if the computer has been up for less than entered threshold.
if ($DaysSinceLastReboot -lt $Threshold) {
    Write-Host "Computer uptime is at $($DaysSinceLastReboot) days. Reboot not needed. Exiting."
    exit 0
}

$PopupDetails = @{
    Title        = if ($env:Title) { $env:Title } else { 'Reboot Recommended' }
    Msg          = if ($env:Message) { $env:Message } else { "To maintain optimal performance, please reboot your computer every $($Threshold) days." }
    RebootButton = if ($env:RebootButton) { $env:RebootButton } else { 'Reboot Now' }
    CancelButton = if ($env:CancelButton) { $env:CancelButton } else { 'Cancel' }
}

$Culture = Get-UICulture
$OSLanguage = $($Culture.TwoLetterISOLanguageName)
if ($env:Language) {
    if ($env:Language.Length -gt 2) {
        Write-Host 'Please use only 2 digit ISO 639 codes. See here for codes:'
        Write-Host 'https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes'
        exit 0
    }
    $OSLanguage = $env:Language
}

if ($ToLanguage -ne 'en') {
    foreach ($Key in @($PopupDetails.Keys)) {
        $PopupDetails[$Key] = Get-Translation -Original $PopupDetails[$Key] -TargetLanguage $OSLanguage
    }
}

$Xaml = @"
  <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
          SizeToContent="WidthAndHeight"
          WindowStartupLocation="CenterScreen"
          ResizeMode="NoResize"
          Topmost="True"
          WindowStyle="ToolWindow"
          ShowInTaskbar="True">
    <Grid Margin="20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="25"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="MessageText"
                 TextWrapping="Wrap"
                 MaxWidth="400"
                 FontSize="16"/>
      <StackPanel Grid.Row="2"
                  Orientation="Horizontal"
                  HorizontalAlignment="Right">
        <Button x:Name="RebootButton" Margin="0,10,10,0" Padding="14,8"/>
        <Button x:Name="CancelButton" Margin="0,10,0,0" Padding="14,8"/>
      </StackPanel>
    </Grid>
  </Window>
"@
  
$ReadXaml = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($ReadXaml)
  
$Window.Title = $PopupDetails.Title
$MessageText = $Window.FindName('MessageText')
$RebootButton = $Window.FindName('RebootButton')
$CancelButton = $Window.FindName('CancelButton')
$MessageText.Text = $PopupDetails.Msg
$RebootButton.Content = $PopupDetails.RebootButton
$CancelButton.Content = $PopupDetails.CancelButton

Add-Type -AssemblyName WindowsBase | Out-Null
$TimeoutMinutes = 3
$StopTime = (Get-Date).AddMinutes($TimeoutMinutes)

$CancelButton.Content = ("{0} ({1:mm\:ss})" -f $PopupDetails.Cancel, ([TimeSpan]::FromMinutes($TimeoutMinutes)))

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
$Timer.Add_Tick({
        $Remaining = $StopTime - (Get-Date)
        if ($Remaining -le [TimeSpan]::Zero) {
            $Timer.Stop()
            $Window.Close()
            return
        }
        $CancelButton.Content = ("{0} ({1:mm\:ss})" -f $PopupDetails.CancelButton, $Remaining)
    })
  
$Timer.Start()
    
$RebootButton.Add_Click({
        $Timer.Stop()
        try {
            Restart-Computer -Force
        }
        catch {
            Write-Host "Failed to restart computer. The following error occured:"
            Write-Host "$($_.Exception.Message)"
        }
        $Window.Close()
    })

$CancelButton.Add_Click({ $Window.Close() })
  
[void]$Window.ShowDialog()

exit 0