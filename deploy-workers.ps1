# =============================================================================
#
#   WORKER SERVER - Panel Deployment
#   Author: Abdulrahman
#   Date: 15/10/2025
#   Version: 24.10.1-worker
#
#   Deploys worker servers: 3x-ui panel with SSL and a bandwidth API.
#   Includes API Key support.
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
    Write-Host "[ERROR] 'config.json' not found. Make sure you copied the example file and filled it out." -ForegroundColor Red
    exit 1
}

# --- Map config to variables ---
$WorkerServers = $config.WorkerServers
$SshUser = $config.Ssh.User
$LocalPublicKeyPath = $config.Ssh.LocalPublicKeyPath
$Local_3xui_Db_Folder = $config.LocalPaths.'3xui_Db_Folder'
$Local_Bandwidth_Path = Split-Path -Path $config.LocalPaths.Bandwidth_Api_File
$CloudflareEmail = $config.Cloudflare.Email
$CloudflareApiKey = $config.Cloudflare.ApiKey
$AppUser = $config.App.User
$AppUserPassword = $config.App.Password
$BandwidthApiKey = $config.BandwidthApiKey

# --- Python packages needed ---
$PythonRequirements_Bandwidth = "fastapi[all] psutil uvicorn"
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
foreach ($server in $WorkerServers) {
    Write-Log "--- STARTING DEPLOYMENT: WORKER ($($server.IpAddress)) ---"

    # --- Step 1: Base System Setup ---
    try {
        Write-Log "Updating system and installing base packages..."
        $baseDependencies = "python3.12 python3.12-venv build-essential python3.12-dev"
        $baseSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
APP_USER_PASSWORD="{1}"
DEPENDENCIES="{2}"
echo "[VPS] Updating packages..."
apt-get update -y > /dev/null
echo "[VPS] Installing: $DEPENDENCIES..."
apt-get install -y $DEPENDENCIES > /dev/null
echo "[VPS] Creating user '$APP_USER'..."
useradd -m -s /bin/bash "$APP_USER" || true
echo "[VPS] Setting password for '$APP_USER' and adding to sudo..."
echo "$APP_USER:$APP_USER_PASSWORD" | chpasswd
usermod -aG sudo "$APP_USER"
'@ -f $AppUser, $AppUserPassword, $baseDependencies
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $baseSetupScript
        Write-Log "Base system setup is complete." -Type "SUCCESS"
    }
    catch {
        Write-Log "Base system setup failed. Skipping this server. ERROR: $($_.Exception.Message)" -Type "ERROR"; continue
    }

    # --- Step 2: Deploy SSH Key ---
    try {
        Write-Log "Deploying your personal SSH key..."
        $personalKey = (Get-Content -Raw $LocalPublicKeyPath).Trim()
        $keyDeployScript = @'
#!/bin/bash
set -e
PERSONAL_KEY="{0}"
APP_USER="{1}"
echo "[VPS] Adding SSH key to root user..."
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$PERSONAL_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
echo "[VPS] Adding SSH key to $APP_USER user..."
install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/$APP_USER/.ssh"
echo "$PERSONAL_KEY" > "/home/$APP_USER/.ssh/authorized_keys"
chown "$APP_USER:$APP_USER" "/home/$APP_USER/.ssh/authorized_keys"
chmod 600 "/home/$APP_USER/.ssh/authorized_keys"
'@ -f $personalKey, $AppUser
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $keyDeployScript
        Write-Log "SSH key deployed." -Type "SUCCESS"
    }
    catch {
        Write-Log "Failed to deploy SSH key. Skipping this server. ERROR: $($_.Exception.Message)" -Type "ERROR"; continue
    }

    # --- Step 3: Install & Configure 3x-ui ---
    try {
        Write-Log "Installing 3x-ui panel..."
        $xuiInstallScript = @'
#!/bin/bash
set -e
echo "[VPS] Running 3x-ui installer..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
echo "[VPS] Stopping x-ui service for db restore..."
x-ui stop
'@
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $xuiInstallScript
        
        Write-Log "Uploading 3x-ui database..."
        $localXuiDbPath = Join-Path $Local_3xui_Db_Folder "$($server.IpAddress)_x-ui.db"
        if (-not (Test-Path $localXuiDbPath -PathType Leaf)) {
            throw "3x-ui database for server $($server.IpAddress) not found at '$localXuiDbPath'"
        }
        Invoke-ScpUpload -IpAddress $server.IpAddress -LocalPath $localXuiDbPath -RemotePath "/etc/x-ui/x-ui.db"
        
        Write-Log "Applying SSL certificate..."
        $sslSetupScript = @'
#!/bin/bash
set -e
echo "[VPS] Restarting x-ui and getting SSL cert..."
x-ui start
sleep 5
printf "19\ny\n{0}\n{1}\n{2}\nn\ny\n\n" | x-ui
'@ -f $server.Domain, $CloudflareApiKey, $CloudflareEmail
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $sslSetupScript
        Write-Log "3x-ui setup and SSL complete." -Type "SUCCESS"
    }
    catch {
        Write-Log "3x-ui setup failed. Skipping this server. ERROR: $($_.Exception.Message)" -Type "ERROR"; continue
    }

    # --- Step 4: Install Bandwidth API ---
    try {
        Write-Log "Installing the Bandwidth API..."
        $bandwidthSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
PYTHON_REQS="{1}"
API_KEY="{2}"
API_DIR="/home/$APP_USER/bandwidth"
echo "[VPS] Creating directory & venv for Bandwidth API..."
install -d -o "$APP_USER" -g "$APP_USER" "$API_DIR"
sudo -u "$APP_USER" python3.12 -m venv "$API_DIR/venv"
echo "[VPS] Installing Python packages for API..."
sudo -u "$APP_USER" "$API_DIR/venv/bin/pip" install $PYTHON_REQS > /dev/null
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
'@ -f $AppUser, $PythonRequirements_Bandwidth, $BandwidthApiKey
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock $bandwidthSetupScript
        
        Write-Log "Uploading Bandwidth API file..."
        Invoke-ScpUpload -IpAddress $server.IpAddress -LocalPath (Join-Path $Local_Bandwidth_Path "bandwidth.py") -RemotePath "/home/$AppUser/bandwidth/bandwidth.py"
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock "chown ${AppUser}:${AppUser} /home/$AppUser/bandwidth/bandwidth.py"

        Write-Log "Enabling and starting Bandwidth API service..."
        Invoke-SshCommand -IpAddress $server.IpAddress -ScriptBlock "systemctl daemon-reload && systemctl enable --now bandwidth.service"
        Write-Log "Bandwidth API is running." -Type "SUCCESS"
    }
    catch {
        Write-Log "Bandwidth API setup failed. Skipping this server. ERROR: $($_.Exception.Message)" -Type "ERROR"; continue
    }

    Write-Log "WORKER DEPLOYMENT FINISHED for $($server.IpAddress)!" -Type "SUCCESS"
}

Write-Log "ALL WORKER DEPLOYMENTS ARE COMPLETE." -Type "SUCCESS"
#endregion