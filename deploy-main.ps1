# =============================================================================
#
#   MAIN SERVER - Bot & Panel Deployment
#   Author: Abdulrahman
#   Date: 15/10/2025
#   Version: 24.10.2-dashboard
#
#   Deploys the main server: 3x-ui panel, bandwidth API, Discord bots,
#   the PostgreSQL database, and the Streamlit Dashboard.
#
# =============================================================================

#region CONFIGURATION
# This setting makes the script stop if anything fails.
$ErrorActionPreference = "Stop"

# --- BOT SERVICE CONTROL ---
# Set to $true to start/restart bot services after deploying.
# Set to $false to just deploy files without touching the services.
$StartDiscordBots = $true

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
$MainServer = @{
    IpAddress = $config.MainServer.IpAddress
    Role      = "main"
    Domain    = $config.MainServer.Domain
}
$SshUser = $config.Ssh.User
$LocalPublicKeyPath = $config.Ssh.LocalPublicKeyPath
$Local_3xui_Db_Folder = $config.LocalPaths.'3xui_Db_Folder'
$Local_Bandwidth_Path = Split-Path -Path $config.LocalPaths.Bandwidth_Api_File
$Local_Bots_DbPath = $config.LocalPaths.Bots_Db_Dump
$Local_Dashboard_Path = $config.LocalPaths.Dashboard_Folder
$CloudflareEmail = $config.Cloudflare.Email
$CloudflareApiKey = $config.Cloudflare.ApiKey
$BotProjects = $config.BotProjects
$AppUser = $config.App.User
$AppUserPassword = $config.App.Password
$DbUser = $config.Database.User
$DbPassword = $config.Database.Password
$DbName = $config.Database.Name
$BandwidthApiKey = $config.BandwidthApiKey

# --- Python packages needed ---
$PythonRequirements_Bots = "aiohttp discord.py python-dotenv psycopg2 pytz PyNaCl"
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

# --- NEW: Helper function to upload an entire directory ---
function Invoke-ScpUploadDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        [Parameter(Mandatory = $true)]
        [string]$LocalDirectory,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )
    # Use scp's recursive -r flag to copy the directory
    scp -r $LocalDirectory "$SshUser@$IpAddress`:$RemotePath"
    if ($LASTEXITCODE -ne 0) {
        throw "SCP directory upload from '$LocalDirectory' failed."
    }
}
#endregion

#region SCRIPT EXECUTION
Write-Log "--- STARTING DEPLOYMENT: MAIN SERVER ($($MainServer.IpAddress)) ---"

# --- Step 1: Base System Setup ---
try {
    Write-Log "Updating system and installing base packages (including Docker)..."
    $baseDependencies = "python3.12 python3.12-venv build-essential python3.12-dev libpq-dev postgresql postgresql-contrib docker.io docker-compose"
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
echo "[VPS] Adding $APP_USER to docker group..."
usermod -aG docker "$APP_USER" || true
'@ -f $AppUser, $AppUserPassword, $baseDependencies
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $baseSetupScript
    Write-Log "Base system setup is complete." -Type "SUCCESS"
}
catch {
    Write-Log "Base system setup failed. Aborting. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
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
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $keyDeployScript
    Write-Log "SSH key deployed." -Type "SUCCESS"
}
catch {
    Write-Log "Failed to deploy SSH key. Aborting. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
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
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $xuiInstallScript
    
    Write-Log "Uploading 3x-ui database..."
    $localXuiDbPath = Join-Path $Local_3xui_Db_Folder "$($MainServer.IpAddress)_x-ui.db"
    if (-not (Test-Path $localXuiDbPath -PathType Leaf)) {
        throw "3x-ui database for $($MainServer.IpAddress) not found at '$localXuiDbPath'"
    }
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $localXuiDbPath -RemotePath "/etc/x-ui/x-ui.db"
    
    Write-Log "Applying SSL certificate..."
    $sslSetupScript = @'
#!/bin/bash
set -e
echo "[VPS] Restarting x-ui and getting SSL cert..."
x-ui start
sleep 5
printf "19\ny\n{0}\n{1}\n{2}\nn\ny\n\n" | x-ui
'@ -f $MainServer.Domain, $CloudflareApiKey, $CloudflareEmail
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $sslSetupScript
    Write-Log "3x-ui setup and SSL complete." -Type "SUCCESS"
}
catch {
    Write-Log "3x-ui setup failed. Aborting. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
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
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $bandwidthSetupScript
    
    Write-Log "Uploading Bandwidth API file..."
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath (Join-Path $Local_Bandwidth_Path "bandwidth.py") -RemotePath "/home/$AppUser/bandwidth/bandwidth.py"
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "chown ${AppUser}:${AppUser} /home/$AppUser/bandwidth/bandwidth.py"
    
    Write-Log "Enabling and starting Bandwidth API service..."
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "systemctl daemon-reload && systemctl enable --now bandwidth.service"
    Write-Log "Bandwidth API is running." -Type "SUCCESS"
}
catch {
    Write-Log "Bandwidth API setup failed. Aborting. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
}

# --- Step 5: Setup PostgreSQL Database ---
try {
    Write-Log "Setting up PostgreSQL database for bots..."
    $dbSetupScript = @'
#!/bin/bash
set -e
DB_NAME="{0}"
DB_USER="{1}"
DB_PASSWORD="{2}"
echo "[VPS] Starting PostgreSQL..."
systemctl enable --now postgresql
echo "[VPS] Re-creating database and user..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" --quiet
sudo -u postgres psql -c "DROP ROLE IF EXISTS \"$DB_USER\";" --quiet
sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
'@ -f $DbName, $DbUser, $DbPassword
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dbSetupScript
    
    Write-Log "Uploading bot database dump..."
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $Local_Bots_DbPath -RemotePath "/tmp/bot_db.dump"
    
    Write-Log "Restoring bot database..."
    $restoreCommand = "sudo -u postgres pg_restore --clean --if-exists --no-owner --role=$DbUser -d $DbName /tmp/bot_db.dump"
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $restoreCommand
    Write-Log "Bot database is ready." -Type "SUCCESS"
}
catch {
    Write-Log "Bot database setup failed. Aborting. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
}

# --- Step 6: Deploy Discord Bots ---
try {
    Write-Log "Starting Discord bot deployments..."
    $botKeys = ($BotProjects | Get-Member -MemberType NoteProperty).Name
    foreach ($botName in $botKeys) {
        $localBotPath = $BotProjects.$botName
        $remoteBotPath = "/home/$AppUser/$botName"
        Write-Log "Deploying bot: $botName..."
        
        $botSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
BOT_NAME="{2}"
PYTHON_REQS="{3}"

echo "[VPS] Creating directory & venv for $BOT_NAME..."
install -d -o "$APP_USER" -g "$APP_USER" "$REMOTE_PATH"
sudo -u "$APP_USER" python3.12 -m venv "$REMOTE_PATH/venv"
echo "[VPS] Installing Python packages for $BOT_NAME..."
sudo -u "$APP_USER" "$REMOTE_PATH/venv/bin/pip" install $PYTHON_REQS > /dev/null

echo "[VPS] Creating systemd service for $BOT_NAME..."
cat << EOF | tee "/etc/systemd/system/$BOT_NAME.service"
[Unit]
Description=Discord Bot - $BOT_NAME
After=network.target postgresql.service
[Service]
ExecStart=$REMOTE_PATH/venv/bin/python3.12 $REMOTE_PATH/$BOT_NAME"bot.py"
WorkingDirectory=$REMOTE_PATH
Restart=always
User=$APP_USER
Group=$APP_USER
[Install]
WantedBy=multi-user.target
EOF
'@ -f $AppUser, $remoteBotPath, $botName, $PythonRequirements_Bots

        Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $botSetupScript
        $filesToCopy = @(
            (Join-Path $localBotPath ".env"),
            (Join-Path $localBotPath "$($botName)bot.py"),
            (Join-Path $localBotPath "utils.py")
        )
        Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $filesToCopy -RemotePath $remoteBotPath
        Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "chown -R ${AppUser}:${AppUser} $remoteBotPath"
        Write-Log "$botName deployment complete." -Type "SUCCESS"
    }
    
    Write-Log "Reloading systemd and managing bot services..."
    $botServices = ($botKeys | ForEach-Object { "${_}.service" }) -join " "
    $systemdCommand = "systemctl daemon-reload; systemctl enable $botServices"
    if ($StartDiscordBots) {
        Write-Log "Starting bot services..."
        $systemdCommand += "; systemctl restart $botServices"
    }
    else {
        Write-Log "Skipping bot service start as per config." -Type "WARN"
    }
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $systemdCommand
    Write-Log "Bot services configured." -Type "SUCCESS"
}
catch {
    Write-Log "Discord bot deployment failed. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
}

# --- NEW: Step 7: Deploy Streamlit Dashboard ---
try {
    Write-Log "Deploying Streamlit Dashboard..."
    $dashboardDomain = "dashboard.$($MainServer.Domain)"
    $remoteDashboardPath = "/home/$AppUser/dashboard"
    
    # Create directory and .env file for the dashboard
    $dashboardSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="{2}"
DB_USER="{3}"
DB_PASSWORD="{4}"
CADDY_CONFIG="/etc/caddy/Caddyfile"
DASHBOARD_DOMAIN="{5}"

echo "[VPS] Creating directory for Dashboard..."
install -d -o "$APP_USER" -g "$APP_USER" "$REMOTE_PATH"

echo "[VPS] Creating .env file for Dashboard..."
cat << EOF | tee "$REMOTE_PATH/.env"
# Database Credentials
PG_HOST=$DB_HOST
PG_PORT=$DB_PORT
PG_DATABASE=$DB_NAME
PG_USER=$DB_USER
PG_PASSWORD=$DB_PASSWORD
EOF
chown "$APP_USER:$APP_USER" "$REMOTE_PATH/.env"

echo "[VPS] Appending Dashboard config to Caddyfile..."
# This appends the new block to the existing Caddyfile created by 3x-ui
cat << EOF | tee -a "$CADDY_CONFIG"

# Streamlit Dashboard
$DASHBOARD_DOMAIN {
    reverse_proxy localhost:8501
}
EOF

echo "[VPS] Reloading Caddy..."
systemctl reload caddy
'@ -f $AppUser, $remoteDashboardPath, $DbName, $DbUser, $DbPassword, $dashboardDomain

    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dashboardSetupScript

    Write-Log "Uploading Dashboard project files..."
    # Use the new directory upload function
    Invoke-ScpUploadDirectory -IpAddress $MainServer.IpAddress -LocalDirectory $Local_Dashboard_Path -RemotePath $remoteDashboardPath
    
    Write-Log "Building and starting Dashboard container..."
    $dockerRunScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
echo "[VPS] Setting correct permissions on dashboard files..."
chown -R "$APP_USER:$APP_USER" "$REMOTE_PATH"
echo "[VPS] Running docker-compose up as user $APP_USER..."
# Run docker-compose as the $APP_USER
cd "$REMOTE_PATH"
sudo -u "$APP_USER" docker-compose up -d --build
'@ -f $AppUser, $remoteDashboardPath
    
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dockerRunScript
    Write-Log "Streamlit Dashboard is deploying." -Type "SUCCESS"
}
catch {
    Write-Log "Streamlit Dashboard deployment failed. ERROR: $($_.Exception.Message)" -Type "ERROR"; exit 1
}
# --- END OF NEW STEP ---

Write-Log "MAIN SERVER DEPLOYMENT FINISHED!" -Type "SUCCESS"
#endregion