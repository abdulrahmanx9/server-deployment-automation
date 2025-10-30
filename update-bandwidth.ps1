# =============================================================================
#
#   UPDATE BANDWIDTH API
#   Author: Abdulrahman
#   Date: 15/10/2025
#   Version: 24.10.1
#
#   Iterates over all servers defined in config.json and updates the
#   bandwidth.py script and its systemd service file.
#
# =============================================================================

#region CONFIGURATION
# This setting makes the script stop if anything fails.
$ErrorActionPreference = "Stop"

# --- Load settings from config.json ---
try {
    $configPath = Join-Path $PSScriptRoot "config.json"
    $config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}
catch {
    Write-Host "[ERROR] 'config.json' not found. Make sure it's in the same directory." -ForegroundColor Red
    exit 1
}

# --- Map config to variables ---
$SshUser = $config.Ssh.User
$Local_Bandwidth_Path = Split-Path -Path $config.LocalPaths.Bandwidth_Api_File
$AppUser = $config.App.User
$BandwidthApiKey = $config.BandwidthApiKey

# --- Combine main and worker servers into a single list ---
$allServers = @()
$allServers += $config.MainServer
$allServers += $config.WorkerServers
#endregion

#region HELPER FUNCTIONS
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Type = "INFO"
    )
    $color = switch ($Type) {
        "INFO" { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$Type] $Message" -ForegroundColor $color
}

function Invoke-SshCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        [Parameter(Mandatory = $true)]
        [string]$ScriptBlock
    )
    $sanitizedScript = $ScriptBlock.Replace("`r", "")
    $base64Script = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sanitizedScript))
    $remoteCommand = "echo '$base64Script' | base64 --decode | sudo bash"
    
    ssh "$SshUser@$IpAddress" $remoteCommand
    
    if ($LASTEXITCODE -ne 0) {
        throw "Remote command failed (exit code: $LASTEXITCODE)."
    }
}

function Invoke-ScpUpload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        [Parameter(Mandatory = $true)]
        [string[]]$LocalPath,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )
    scp $LocalPath "$SshUser@$IpAddress`:$RemotePath"
    if ($LASTEXITCODE -ne 0) {
        throw "SCP upload from '$LocalPath' failed."
    }
}
#endregion

#region SCRIPT EXECUTION
Write-Log "--- STARTING BANDWIDTH API UPDATE FOR ALL SERVERS ---"

foreach ($server in $allServers) {
    Write-Log "--- Updating Bandwidth API on $($server.IpAddress) ---"
    try {
        # --- Step 1: Upload the updated bandwidth.py file ---
        $remoteBandwidthDir = "/home/$AppUser/bandwidth"
        $remoteBandwidthFile = "$remoteBandwidthDir/bandwidth.py"
        $localBandwidthFile = Join-Path $Local_Bandwidth_Path "bandwidth.py"

        Write-Log "Uploading updated bandwidth.py..."
        Invoke-ScpUpload -IpAddress $server.IpAddress -LocalPath $localBandwidthFile -RemotePath $remoteBandwidthFile
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock "chown ${AppUser}:${AppUser} $remoteBandwidthFile"

        # --- Step 2: Re-create the systemd service file to ensure it's correct ---
        Write-Log "Creating/Updating systemd service file..."
        $serviceUpdateScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
API_KEY="{1}"
API_DIR="{2}"

echo "[VPS] Creating systemd service for Bandwidth API..."
cat << EOF | tee /etc/systemd/system/bandwidth.service
[Unit]
Description=Bandwidth Monitoring API
After=network.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$API_DIR
Environment="BANDWIDTH_API_KEY=$API_KEY"
ExecStart=$API_DIR/venv/bin/uvicorn bandwidth:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
'@ -f $AppUser, $BandwidthApiKey, $remoteBandwidthDir
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $serviceUpdateScript

        # --- Step 3: Reload daemon and restart the service ---
        Write-Log "Reloading systemd and restarting the service..."
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock "systemctl daemon-reload && systemctl restart bandwidth.service"

        Write-Log "Update successful for $($server.IpAddress)!" -Type "SUCCESS"
    }
    catch {
        Write-Log "Update failed for $($server.IpAddress). Skipping. ERROR: $($_.Exception.Message)" -Type "ERROR"; continue
    }
}

Write-Log "ALL BANDWIDTH API UPDATES ARE COMPLETE." -Type "SUCCESS"
#endregion