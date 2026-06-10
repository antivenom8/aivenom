#!/bin/bash

# SYNOPSIS
# This script is used to install the NinjaOne agent. Supports generic installer or generated URL.

# DESCRIPTION
# This script is used to install the NinjaOne agent. Supports generic installer or generated URL.

# ---------------------------------------------------------------
# Author: Mark Giordano
# Date: 05/02/2025
# Description: Install NinjaOne Agent - macOS
# Update: Added additional logic.
# ---------------------------------------------------------------

# Adjust URL to your generated URL or to the generic URL
URL='EnterInstallerURL'
# If using generic installer URL, a token must be provided.
Token='EnterToken'
Folder='/tmp'
Filename=$(basename "$URL")
Pattern='[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

Write_LogEntry() {
   if [[ -z "$1" ]]; then
       Write_LogEntry "Usage: Write_LogEntry \"You must supply a message when calling this function.\""
       return 1
   fi
   local message="$1"
   local log_path="/tmp/NinjaOneReinstall.log"
   local timestamp
   timestamp=$(date +"%Y-%m-%d %H:%M:%S")
   # Append the log entry to the file and print it to the console
   echo "$timestamp - $message" >>"$log_path"
   echo "$timestamp - $message"
}

if [[ $EUID -ne 0 ]]; then
   Write_LogEntry 'This script must be run as root. Try running it with sudo or as the system/root user.'
   exit 1
fi

if [[ -z "$URL" ]]; then
   Write_LogEntry 'No installer URL provided. Cannot continue.'
   exit 1
fi

Write_LogEntry 'Performing checks...'

CheckApp='/Applications/NinjaRMMAgent'
if [[ -d "$CheckApp" ]]; then
    Write_LogEntry 'NinjaOne agent already installed. Please remove before installing.'
    exit 1
fi

if [[ "$Filename" != *.pkg ]]; then
   Write_LogEntry 'Only PKG files are supported in this script. Cannot continue.'
   exit 1
fi

if [[ ! "$URL" =~ $Pattern ]]; then
   if [[ -z "$Token" ]]; then
       Write_LogEntry 'A generic install URL was provided with no token. Please provide a token to use the generic installer. Exiting.'
       exit 1
   fi

   if [[ ! $Token =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
       Write_LogEntry 'An invalid token was provided. Please ensure it was entered correctly.'
       exit 1
   fi

   Write_LogEntry 'Token provided and generic installer being used. Continuing...'
   echo "$Token" >"$Folder/.~"

else
   if [[ -n "$Token" ]]; then
       Write_LogEntry 'A token was provided, but the URL appears to be for a generated installer and not the generic installer.'
       Write_LogEntry 'Script will not continue. Please use either a generic installer URL, or remove the token. You cannot use both.'
       exit 1
   fi
fi

## Download and verify installer.
Write_LogEntry 'Downloading installer...'

if ! curl -fSL "$URL" -o "$Folder/$Filename"; then
   Write_LogEntry 'Download failed. Exiting Script.'
   exit 1
fi

if [[ ! -s "$Folder/$Filename" ]]; then
   Write_LogEntry 'Downloaded an empty file. Exiting.'
   exit 1
fi

if ! pkgutil --check-signature "$Folder/$Filename" | grep -q "NinjaRMM LLC"; then
   Write_LogEntry 'PKG file is not signed by NinjaOne. Cannot continue.'
   exit 1
fi

Write_LogEntry 'Download successful.'
Write_LogEntry 'Beginning installation...'

installer -pkg "$Folder/$Filename" -target /

CheckApp='/Applications/NinjaRMMAgent'

if [[ ! -d "$CheckApp" ]]; then
   Write_LogEntry 'Failed to install the NinjaOne Agent. Exiting.'
   rm "$Folder/$Filename"
   exit 1
fi

Write_LogEntry 'Successfully installed NinjaOne!'

rm "$Folder/$Filename"
exit 0