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

Write-LogEntry() {
    if [[ -z "$1" ]]; then
        Write-LogEntry "Usage: Write-LogEntry \"You must supply a message when calling this function.\""
        return 1
    fi

    local message="$1"

    local log_path="/tmp/NinjaOneInstall.log"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Append the log entry to the file and print it to the console
    echo "$timestamp - $message" >>"$log_path"
    echo "$timestamp - $message"
}

# Adjust URL to your generated URL or to the generic URL
URL=''
# If using generic installer URL, a token must be provided
Token=''
Folder='/tmp'
Filename=$(basename "$URL")

if [[ $EUID -ne 0 ]]; then
    Write-LogEntry "This script must be run as root. Try running it with sudo or as the system/root user."
    exit 1
fi

if [[ -z "$URL" ]]; then
    Write-LogEntry 'Please provide a URL. Exiting.'
    exit 1
fi

Write-LogEntry 'Performing checks...'

CheckApp='/Applications/NinjaRMMAgent'
if [[ -d "$CheckApp" ]]; then
    Write-LogEntry 'NinjaOne agent already installed. Please remove before installing.'
    rm "$Folder/$Filename"
    exit 1
fi

if [[ "$Filename" != *.pkg ]]; then
    Write-LogEntry 'Only PKG files are supported in this script. Cannot continue.'
    exit 1
fi

if [[ "$Filename" == 'NinjaOneAgent-x64.pkg' ]]; then
    if [[ -z "$Token" ]]; then
        Write-LogEntry 'A generic install URL was provided with no token. Please provide a token to use the generic installer. Exiting.'
        exit 1
    fi

    if [[ ! $Token =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        Write-LogEntry 'An invalid token was provided. Please ensure it was entered correctly.'
        exit 1
    fi

    Write-LogEntry 'Token provided and generic installer being used. Continuing...'
    echo "$Token" >"$Folder/.~"
else
    if [[ -n "$Token" ]]; then
        Write-LogEntry 'A token was provided, but the URL appears to be for a generated installer and not the generic installer.'
        Write-LogEntry 'Script will not continue. Please use either a generic installer URL, or remove the token. You cannot use both.'
        exit 1
    fi
fi

Write-LogEntry 'Downloading installer...'

if ! curl -fSL "$URL" -o "$Folder/$Filename"; then
    Write-LogEntry 'Download failed. Exiting Script.'
    exit 1
fi

if [[ ! -s "$Folder/$Filename" ]]; then
    Write-LogEntry 'Downloaded an empty file. Exiting.'
    exit 1
fi

if ! pkgutil --check-signature "$Folder/$Filename" | grep -q "NinjaRMM LLC"; then
    Write-LogEntry 'PKG file is not signed by NinjaOne. Cannot continue.'
    exit 1
fi

Write-LogEntry 'Download successful. Beginning installation...'

installer -pkg "$Folder/$Filename" -target /

CheckApp='/Applications/NinjaRMMAgent'
if [[ ! -d "$CheckApp" ]]; then
    Write-LogEntry 'Failed to install the NinjaOne Agent. Exiting.'
    rm "$Folder/$Filename"
    exit 1
fi

Write-LogEntry 'Successfully installed NinjaOne!'
rm "$Folder/$Filename"
exit 0
