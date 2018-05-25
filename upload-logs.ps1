# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2018 Jacob Keller. All rights reserved.

# Terminate on all errors...
$ErrorActionPreference = Stop

# Path to JSON-formatted configuration file
$config_file = "l0g-101086-config.json"

# Relevant customizable configuration fields

# extra_upload_data
#
# This script requires some extra data generated by upload-logs.ps1 and stored
# in a particular location. This data is generated by the C++ simpleArcParse
# utility, in addition to the upload-logs.ps1 script itself. It contains a series
# of directories key'd off of the local evtc file name, and each folder hosts
# JSON formatted data for the player accounts who participated, the success/failure
# and the uploaded dps.report link if any.

# gw2raidar_start_map
#
# This script correlates gw2raidar links to the local evtc files (and thus the dps.report files)
# by using the server start time associated with the log. It parses this data out using
# simpleArcParse, which is a C++ program designed to read minimal data from evtc files.
#
# Gw2raidar does not currently provide the original file upload, so we match it based on the
# server start time. To do so, upload-logs.ps1 stores a folder within $gw2raidar_start_map named
# after the start time of the encounter, and inside this, hosts a JSON data file which contains
# the local evtc file name. This essenitally builds a mini-database for mapping gw2raidar
# links back to local evtc files so we can obtain player names and the dps.report links

# restsharp_path
#
# This script relies on RestSharp (http://restsharp.org/) because the built in
# "Invoke-WebRequest" was not able to work for all uses needed. This should
# be the complete path to the RestSharp.dll as obtained from RestSharp's website.

# simple_arc_parse_path
#
# Path to the compiled binary simpleArcParse utility, intended for doing minimal work to extract
# useful data from local evtc files.

# last_upload_file
#
# Path to a file to store JSON formatted time data used to prevent re-upload of previous logs

# arcdps_logs
#
# Path to the folder where ArcDPS is configured to store evtc files. We recursively scan this
# directory, so any of the options to add extra path elements are safe to use and should
# not prevent finding of evtc log files

# gw2raidar_token
#
# This is the token obtained from gw2raidar's API, in connection with your account.
# It can be obtained through a webbrowser by logging into gw2raidar.com and visiting
# "https://www.gw2raidar.com/api/v2/swagger#/token"

# dps_report_token
#
# This is the API token used to upload files to dps.report. Currently this is choosable
# by the uploader and is only going to be used in future API updates for finding uploaded logs
# For now, this can be set to any random unique string.

# upload_log_file
#
# File used to store output of the upload-logs.ps1 script for later debugging

# custom_tags_script
#
# Set this to the path of a powershell script which can be dot sourced to provide
# custom tagging logic used to determine what tags and category to set for gw2raidar

# debug_mode
#
# Switches output to display to the console instead of the log file.

$config = Get-Content -Raw -Path $config_file | ConvertFrom-Json

# Allow path configurations to contain %UserProfile%, replacing them with the environment variable
$config | Get-Member -Type NoteProperty | where { $config."$($_.Name)" -is [string] } | ForEach-Object {
    $config."$($_.Name)" = ($config."$($_.Name)").replace("%UserProfile%", $env:USERPROFILE)
}

# Load relevant configuration variables
$last_upload_file = $config.last_upload_file
$arcdps_logs = $config.arcdps_logs
$gw2raidar_token = $config.gw2raidar_token
$dpsreport_token = $config.dps_report_token
$logfile = $config.upload_log_file

# Simple storage format for extra ancillary data about uploaded files
$extra_upload_data = $config.extra_upload_data
$gw2raidar_start_map = $config.gw2raidar_start_map
$simple_arc_parse = $config.simple_arc_parse_path

$gw2raidar_url = "https://www.gw2raidar.com"
$dpsreport_url = "https://dps.report"

Add-Type -Path $config.restsharp_path
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function Log-Output ($string) {
    if ($config.debug_mode) {
        Write-Output $string
    } else {
        Write-Output $string | Out-File -Append $logfile
    }
}

# If we have a last upload file, we want to limit our scan to all files since
# the last time that we uploaded.
#
# This invocation is a bit complicated, but essentially we recurse through all folders within
# the $arcdps_logs directory and find all files which end in *.evtc.zip. We store them by the
# last write time, and then we return the full path of that file.
if (Test-Path $last_upload_file) {
    $last_upload_time = Get-Content -Raw -Path $last_upload_file | ConvertFrom-Json | Select-Object -ExpandProperty "DateTime" | Get-Date
    $files = @(Get-ChildItem -Recurse -File -Include @(".evtc.zip", "*.evtc") -LiteralPath $arcdps_logs | Where-Object { $_.LastWriteTime -gt $last_upload_time} | Sort-Object -Property LastWriteTime | ForEach-Object {$_.FullName})
} else {
    $files = @(Get-ChildItem -Recurse -File -Include @(".evtc.zip", "*.evtc") -LiteralPath $arcdps_logs | Sort-Object -Property LastWriteTime | ForEach-Object {$_.FullName})
}

$next_upload_time = Get-Date
Log-Output "~~~"
Log-Output "Uploading arcdps logs at $next_upload_time..."
Log-Output "~~~"

# Main loop to generate and upload gw2raidar and dps.report files
ForEach($f in $files) {
    $name = [io.path]::GetFileNameWithoutExtension($f)
    Log-Output "Saving ancillary data for ${name}..."

    $dir = Join-Path -Path $extra_upload_data -ChildPath $name
    if (Test-Path -Path $dir) {
        Log-Output "Ancillary data appears to have already been created... skipping"
    } else {
        # Make the ancillary data directory
        New-Item -ItemType Directory -Path $dir

        if ($f -Like "*.evtc.zip") {
            # simpleArcParse cannot deal with compressed data, so we must uncompress
            # it first, before passing the file to the simpleArcParse program
            [io.compression.zipfile]::ExtractToDirectory($f, $dir) | Out-Null

            $evtc = Join-Path -Path $dir -ChildPath $name
        } else {
            # if the file was not compressed originally, we don't need to copy it
            $evtc = $f
        }

        # Parse the evtc file and extract account names
        $player_data = (& $simple_arc_parse players "${evtc}")
        $players = $player_data.Split([Environment]::NewLine)
        $players | ConvertTo-Json | Out-File -FilePath (Join-Path $dir -ChildPath "accounts.json")

        # Parse the evtc header file and get the encounter name
        $evtc_header_data = (& $simple_arc_parse header "${evtc}")
        $evtc_header = ($evtc_header_data.Split([Environment]::NewLine))
        $evtc_header[0] | ConvertTo-Json | Out-File -FilePath (Join-Path $dir -ChildPath "version.json")
        $evtc_header[1] | ConvertTo-Json | Out-File -FilePath (Join-Path $dir -ChildPath "encounter.json")

        # Parse the evtc combat events to determine SUCCESS/FAILURE status
        $evtc_success = (& $simple_arc_parse success "${evtc}")
        $evtc_success | ConvertTo-Json | Out-File -FilePath (Join-Path $dir -ChildPath "success.json")

        # Parse the evtc combat events to determine the server start time
        $start_time = (& $simple_arc_parse start_time "${evtc}")

        # Generate a map between start time and the evtc file name
        $map_dir = Join-Path -Path $gw2raidar_start_map -ChildPath $start_time
        if (Test-Path -Path $map_dir) {
            $recorded_name = Get-Content -Raw -Path (Join-Path -Path $map_dir -ChildPath "evtc.json") | ConvertFrom-Json
            if ($recorded_name -ne $name) {
                Log-Output "$recorded_name was already mapped to this start time...!"
            }
        } else {
            # Make the mapping directory
            New-Item -ItemType Directory -Path $map_dir

            $name | ConvertTo-Json | Out-File -FilePath (Join-Path $map_dir -ChildPath "evtc.json")
        }

        # If the file was originally compressed, there's no need to keep around the uncompressed copy
        if ($f -ne $evtc) {
            Remove-Item -Path $evtc
        }
    }

    # First, upload to gw2raidar, because it returns immediately and processes in the background
    Log-Output "Uploading ${name} to gw2raidar..."
    try {
        $client = New-Object RestSharp.RestClient($gw2raidar_url)
        $req = New-Object RestSharp.RestRequest("/api/v2/encounters/new")
        $req.AddHeader("Authorization", "Token $gw2raidar_token") | Out-Null
        $req.Method = [RestSharp.Method]::PUT

        $req.AddFile("file", $f) | Out-Null

        $day = (Get-Item $f).LastWriteTime.DayOfWeek
        $time = (Get-Item $f).LastWriteTime.TimeOfDay

        # Handle custom logic for including tag and category information
        if (Test-Path $config.custom_tags_script) {
            . $config.custom_tags_script
        }

        $resp = $client.Execute($req)

        if ($resp.ResponseStatus -ne [RestSharp.ResponseStatus]::Completed) {
            throw "Request was not completed"
        }

        # Comment this out if you want to log the entire response content
        # even on successful runs
        # Log-Output $resp.Content

        if ($resp.StatusCode -ne "OK") {
            Log-Output $resp.Content
            throw "Request failed with status $resp.StatusCode"
        }
        Log-Output "Upload successful..."
    } catch {
        Log-Output $_.Exception.Message
        Log-Output "Upload to gw2raidar failed..."

        # The set of files is sorted in ascending order by its last write time. This
        # means, if we exit at the first failed file, that all files with an upload time prior
        # to this file must have succeeded. Thus, we'll save the "last upload time" as the
        # last update time of this file minus a little bit to ensure we attempt re-uploading it
        # on the next run. This avoids re-uploading lots of files if we fail in the middle of
        # a large sequence.
        (Get-Item $f).LastWriteTime.AddSeconds(-1) | Select-Object -Property DateTime | ConvertTo-Json | Out-File -Force $last_upload_file
        exit
    }

    # We opted to only upload successful logs to dps.report, but all logs to gw2raidar.
    # You could remove this code if you want dps.report links for all encounters.
    $status = Get-Content -Raw -Path (Join-Path -Path $dir -ChildPath "success.json") | ConvertFrom-Json
    if ($status -ne "SUCCESS") {
        continue
    }

    Log-Output "Uploading ${name} to dps.report..."
    try {
        $client = New-Object RestSharp.RestClient($dpsreport_url)
        $req = New-Object RestSharp.RestRequest("/uploadContent")
        $req.Method = [RestSharp.Method]::POST

        # This depends on the json output being enabled
        $req.AddParameter("json", "1") | Out-Null
        # We wanted weapon rotations, but you can disable this if you like
        $req.AddParameter("rotation_weap", "1") | Out-Null
        # Include the dps.report user token
        $req.AddParameter("userToken", $dpsreport_token)

        $req.AddFile("file", $f) | Out-Null

        $resp = $client.Execute($req)

        if ($resp.ResponseStatus -ne [RestSharp.ResponseStatus]::Completed) {
            throw "Request was not completed"
        }

        if ($resp.StatusCode -ne "OK") {
            $json_resp = ConvertFrom-Json $resp.Content
            Log-Output $json_resp.error
            throw "Request failed with status $resp.StatusCode"
        }

        $resp.Content | Out-File -FilePath (Join-Path $dir -ChildPath "dpsreport.json")

        Log-Output "Upload successful..."
    } catch {
        Log-Output $_.Exeception.Message
        Log-Output "Upload to dps.report failed..."

        # The set of files is sorted in ascending order by its last write time. This
        # means, if we exit at the first failed file, that all files with an upload time prior
        # to this file must have succeeded. Thus, we'll save the "last upload time" as the
        # last update time of this file minus a little bit to ensure we attempt re-uploading it
        # on the next run. This avoids re-uploading lots of files if we fail in the middle of
        # a large sequence.
        (Get-Item $f).LastWriteTime.AddSeconds(-1) | Select-Object -Property DateTime | ConvertTo-Json | Out-File -Force $last_upload_file
        exit
    }
}

# Save the current time as
$next_upload_time | Select-Object -Property DateTime| ConvertTo-Json | Out-File -Force $last_upload_file
