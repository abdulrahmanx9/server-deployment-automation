# =============================================================================
#
#   MAIN SERVER - Full Stack Deployment
#   Author: Abdulrahman
#   Date: 13/11/2025
#   Version: 25.0.0-Final-Release
#
#   Deploys: 
#   1. System Dependencies & Docker
#   2. SSH Keys
#   3. 3x-ui Panel (SSL enabled)
#   4. Bandwidth API (FastAPI)
#   5. PostgreSQL Database (Restore from dump)
#   6. Discord Bots (Python)
#   7. Streamlit Dashboard (Docker + Caddy)
#
# =============================================================================

#region CONFIGURATION
$ErrorActionPreference = "Stop"

# --- BOT SERVICE CONTROL ---
# Set to $true to start/restart bot services after deploying.
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
$PythonRequirements_Bandwidth = "fastapi[all] psutil uvicorn"
#endregion

#region HELPER FUNCTIONS
function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
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
    param([string]$IpAddress, [string]$ScriptBlock)
    $sanitizedScript = $ScriptBlock.Replace("`r", "")
    $base64Script = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sanitizedScript))
    $remoteCommand = "echo '$base64Script' | base64 --decode | sudo bash"
    ssh "$SshUser@$IpAddress" $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed (exit code: $LASTEXITCODE)." }
}

function Invoke-ScpUpload {
    param([string]$IpAddress, [string[]]$LocalPath, [string]$RemotePath)
    # Filter out paths that don't exist locally
    $existingPaths = $LocalPath | Where-Object { Test-Path $_ -PathType Leaf }
    if ($existingPaths.Count -eq 0) {
        Write-Log "No valid files found to upload for destination: $RemotePath" -Type "WARN"
        return
    }
    scp $existingPaths "$SshUser@$IpAddress`:$RemotePath"
    if ($LASTEXITCODE -ne 0) { Write-Log "SCP upload warning. Some files might be missing." -Type "WARN" }
}
#endregion

#region SCRIPT EXECUTION
Write-Log "--- STARTING DEPLOYMENT: MAIN SERVER ($($MainServer.IpAddress)) ---"

# --- Step 1: Base System Setup ---
try {
    Write-Log "1. Updating system and installing base packages..."
    $baseDependencies = "python3.12 python3.12-venv build-essential python3.12-dev libpq-dev postgresql postgresql-contrib docker.io docker-compose"
    $baseSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
APP_USER_PASSWORD="{1}"
DEPENDENCIES="{2}"
apt-get update -y > /dev/null
apt-get install -y $DEPENDENCIES > /dev/null
useradd -m -s /bin/bash "$APP_USER" || true
echo "$APP_USER:$APP_USER_PASSWORD" | chpasswd
usermod -aG sudo "$APP_USER"
usermod -aG docker "$APP_USER" || true
'@ -f $AppUser, $AppUserPassword, $baseDependencies
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $baseSetupScript
    Write-Log "Base system setup complete." -Type "SUCCESS"
}
catch { Write-Log "Base setup failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 2: Deploy SSH Key ---
try {
    Write-Log "2. Deploying SSH key..."
    $personalKey = (Get-Content -Raw $LocalPublicKeyPath).Trim()
    $keyDeployScript = @'
#!/bin/bash
set -e
PERSONAL_KEY="{0}"
APP_USER="{1}"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$PERSONAL_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/$APP_USER/.ssh"
echo "$PERSONAL_KEY" > "/home/$APP_USER/.ssh/authorized_keys"
chown "$APP_USER:$APP_USER" "/home/$APP_USER/.ssh/authorized_keys"
chmod 600 "/home/$APP_USER/.ssh/authorized_keys"
'@ -f $personalKey, $AppUser
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $keyDeployScript
    Write-Log "SSH key deployed." -Type "SUCCESS"
}
catch { Write-Log "SSH key deployment failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 3: Install & Configure 3x-ui ---
try {
    Write-Log "3. Installing 3x-ui panel..."
    $xuiInstallScript = @'
#!/bin/bash
set -e
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
x-ui stop
'@
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $xuiInstallScript
    
    Write-Log "Uploading 3x-ui database..."
    $localXuiDbPath = Join-Path $Local_3xui_Db_Folder "$($MainServer.IpAddress)_x-ui.db"
    if (-not (Test-Path $localXuiDbPath)) { throw "3x-ui database not found at '$localXuiDbPath'" }
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $localXuiDbPath -RemotePath "/etc/x-ui/x-ui.db"
    
    Write-Log "Applying SSL certificate..."
    $sslSetupScript = @'
#!/bin/bash
set -e
x-ui start
sleep 5
printf "19\ny\n{0}\n{1}\n{2}\nn\ny\n\n" | x-ui
'@ -f $MainServer.Domain, $CloudflareApiKey, $CloudflareEmail
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $sslSetupScript
    Write-Log "3x-ui setup complete." -Type "SUCCESS"
}
catch { Write-Log "3x-ui setup failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 4: Install Bandwidth API ---
try {
    Write-Log "4. Installing Bandwidth API..."
    $bandwidthSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
PYTHON_REQS="{1}"
API_KEY="{2}"
API_DIR="/home/$APP_USER/bandwidth"
install -d -o "$APP_USER" -g "$APP_USER" "$API_DIR"
sudo -u "$APP_USER" python3.12 -m venv "$API_DIR/venv"
sudo -u "$APP_USER" "$API_DIR/venv/bin/pip" install $PYTHON_REQS > /dev/null
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
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "systemctl daemon-reload && systemctl enable --now bandwidth.service"
    Write-Log "Bandwidth API running." -Type "SUCCESS"
}
catch { Write-Log "Bandwidth API setup failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 5: Setup PostgreSQL Database ---
try {
    Write-Log "5. Setting up PostgreSQL..."
    $dbSetupScript = @'
#!/bin/bash
set -e
DB_NAME="{0}"
DB_USER="{1}"
DB_PASSWORD="{2}"
systemctl enable --now postgresql
sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" --quiet
sudo -u postgres psql -c "DROP ROLE IF EXISTS \"$DB_USER\";" --quiet
sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
'@ -f $DbName, $DbUser, $DbPassword
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dbSetupScript
    
    Write-Log "Restoring bot database..."
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $Local_Bots_DbPath -RemotePath "/tmp/bot_db.dump"
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "sudo -u postgres pg_restore --clean --if-exists --no-owner --role=$DbUser -d $DbName /tmp/bot_db.dump"
    Write-Log "Database restored." -Type "SUCCESS"
}
catch { Write-Log "Database setup failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 6: Deploy Discord Bots ---
try {
    Write-Log "6. Deploying Discord bots..."
    $botKeys = ($BotProjects | Get-Member -MemberType NoteProperty).Name
    foreach ($botName in $botKeys) {
        $localBotPath = $BotProjects.$botName
        $remoteBotPath = "/home/$AppUser/$botName"
        Write-Log "Processing $botName..."
        
        $botSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
BOT_NAME="{2}"
install -d -o "$APP_USER" -g "$APP_USER" "$REMOTE_PATH"
sudo -u "$APP_USER" python3.12 -m venv "$REMOTE_PATH/venv"
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
'@ -f $AppUser, $remoteBotPath, $botName
        Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $botSetupScript
        
        # Upload specific files
        $filesToCopy = @(
            (Join-Path $localBotPath ".env"), (Join-Path $localBotPath "$($botName)bot.py"),
            (Join-Path $localBotPath "utils.py"), (Join-Path $localBotPath "db.py"),
            (Join-Path $localBotPath "models.py"), (Join-Path $localBotPath "requirements.txt"),
            (Join-Path $localBotPath "fuckingfast.py")
        )
        Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $filesToCopy -RemotePath $remoteBotPath
        
        # Install Requirements
        $installScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
if [ -f "$REMOTE_PATH/requirements.txt" ]; then
    sudo -u "$APP_USER" "$REMOTE_PATH/venv/bin/pip" install -r "$REMOTE_PATH/requirements.txt" > /dev/null
fi
chown -R "$APP_USER:$APP_USER" "$REMOTE_PATH"
'@ -f $AppUser, $remoteBotPath
        Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $installScript
    }
    
    # Manage Services
    $botServices = ($botKeys | ForEach-Object { "${_}.service" }) -join " "
    $cmd = "systemctl daemon-reload; systemctl enable $botServices"
    if ($StartDiscordBots) { $cmd += "; systemctl restart $botServices" }
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $cmd
    Write-Log "Bots deployed." -Type "SUCCESS"
}
catch { Write-Log "Bot deployment failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }

# --- Step 7: Deploy Streamlit Dashboard ---
try {
    Write-Log "7. Deploying Streamlit Dashboard..."
    $dashboardDomain = "dashboard.$($MainServer.Domain)"
    $remoteDashboardPath = "/home/$AppUser/dashboard"
    
    $dashboardSetupScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
DB_NAME="{2}"
DB_USER="{3}"
DB_PASSWORD="{4}"
CADDY_CONFIG="/etc/caddy/Caddyfile"
DASHBOARD_DOMAIN="{5}"

# 1. Check and Install Caddy
if ! command -v caddy &> /dev/null; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update && apt-get install -y caddy
fi

# 2. Setup Directory & .env
install -d -o "$APP_USER" -g "$APP_USER" "$REMOTE_PATH"
cat << EOF | tee "$REMOTE_PATH/.env"
PG_HOST=localhost
PG_PORT=5432
PG_DATABASE=$DB_NAME
PG_USER=$DB_USER
PG_PASSWORD=$DB_PASSWORD
EOF
chown "$APP_USER:$APP_USER" "$REMOTE_PATH/.env"

# 3. Configure Caddy
mkdir -p /etc/caddy
if [ ! -f "$CADDY_CONFIG" ]; then touch "$CADDY_CONFIG"; fi

if grep -q "$DASHBOARD_DOMAIN" "$CADDY_CONFIG"; then
    echo "[VPS] Domain already in Caddyfile."
else
    echo "[VPS] Appending config to Caddyfile..."
    cat << EOF | tee -a "$CADDY_CONFIG"

$DASHBOARD_DOMAIN {{
    reverse_proxy localhost:8501
}}
EOF
    systemctl enable --now caddy
    systemctl reload caddy
fi
'@ -f $AppUser, $remoteDashboardPath, $DbName, $DbUser, $DbPassword, $dashboardDomain

    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dashboardSetupScript

    Write-Log "Uploading Dashboard files..."
    # Clear old files
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock "rm -rf $remoteDashboardPath/*"
    
    # Upload ONLY specific files (Avoids local venv junk)
    $dashboardFiles = @(
        "dashboard.py", 
        "docker-compose.yml", 
        "Dockerfile", 
        "requirements.txt", 
        "config.yaml"
    )
    $filesToUpload = $dashboardFiles | ForEach-Object { Join-Path $Local_Dashboard_Path $_ }
    Invoke-ScpUpload -IpAddress $MainServer.IpAddress -LocalPath $filesToUpload -RemotePath $remoteDashboardPath

    Write-Log "Starting Dashboard Container..."
    $dockerRunScript = @'
#!/bin/bash
set -e
APP_USER="{0}"
REMOTE_PATH="{1}"
chown -R "$APP_USER:$APP_USER" "$REMOTE_PATH"
cd "$REMOTE_PATH"
if docker compose version >/dev/null 2>&1; then
    sudo -u "$APP_USER" docker compose up -d --build
else
    sudo -u "$APP_USER" docker-compose up -d --build
fi
'@ -f $AppUser, $remoteDashboardPath
    
    Invoke-SshCommand -IpAddress $MainServer.IpAddress -ScriptBlock $dockerRunScript
    Write-Log "Streamlit Dashboard deployed successfully!" -Type "SUCCESS"
}
catch { Write-Log "Dashboard deployment failed: $($_.Exception.Message)" -Type "ERROR"; exit 1 }
# --- END OF STEP 7 ---

Write-Log "MAIN SERVER DEPLOYMENT FINISHED!" -Type "SUCCESS"
#endregion