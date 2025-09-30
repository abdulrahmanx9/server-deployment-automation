# PowerShell VPS Deployment Suite

This repository contains a collection of PowerShell scripts designed to automate the setup and deployment of a multi-server infrastructure. This suite facilitates the deployment of the 3x-ui panel, a custom bandwidth monitoring API, a PostgreSQL database, and multiple Discord bots onto fresh Debian-based Linux servers.

---

## Features

* **Automated Server Provisioning**: Automates user creation, system dependency installation, and SSH key deployment on new servers.
* **Main Server Deployment**: Provisions a central server with the 3x-ui panel, a PostgreSQL database, the bandwidth API, and all Discord bots.
* **Worker Server Deployment**: Provisions one or more worker servers with the 3x-ui panel and the bandwidth API.
* **Centralized Configuration**: Leverages a single `config.json` file for managing all server details, paths, and credentials.
* **SSL Automation**: Automatically obtains and applies SSL certificates for 3x-ui panels using Cloudflare credentials.
* **Database Management**: Handles the restoration of a PostgreSQL database from a specified local dump file.
* **Service Management**: Manages `systemd` services for all deployed applications (API, bots), ensuring they are enabled for resilience and automatic restarts.

---

## Architecture Overview

This deployment system is based on a main/worker server architecture:

* **`deploy-main.ps1`**: This script provisions the **main server**, which acts as the central hub hosting the primary 3x-ui panel, the PostgreSQL database utilized by the Discord bots, and the bot applications themselves.
* **`deploy-workers.ps1`**: This script provisions one or more **worker servers**. These are supplementary nodes, each running an independent instance of the 3x-ui panel and the bandwidth API.

---

## Prerequisites

### Local Machine

* Windows with PowerShell 7 or later.
* **OpenSSH Client**: `ssh.exe` and `scp.exe` must be installed and accessible via the system's PATH environment variable.
* **SSH Key**: A passwordless SSH public key (e.g., `id_ed25519.pub`) must be available at a specified local path.
* **Project Files**: The following project files must be available on the local machine:
    * The database dump file (`db.dump`).
    * The `bandwidth.py` API source file.
    * The source code for each Discord bot.
    * Pre-configured `x-ui.db` files for each server, named according to the convention `<IP_ADDRESS>_x-ui.db`.

### Remote Servers

* A Debian-based Linux distribution (e.g., Debian, Ubuntu) is required, as the scripts use the `apt-get` package manager.
* Initial root access via password is required; the script will subsequently install an SSH key for passwordless authentication.

---

## Setup and Configuration

1.  **Clone the Repository**:
    ```bash
    git clone <your-repository-url>
    cd <repository-directory>
    ```

2.  **Create Configuration File**:
    Rename the `config.example.json` file to `config.json`.

3.  **Complete the `config.json` File**:
    Populate the `config.json` file with the specific server details, paths, and credentials for your environment.

    * `MainServer`: The IP address and domain for the main server.
    * `WorkerServers`: An array of objects, each containing the IP address and domain for a worker server.
    * `Ssh`: The remote username (`root` for initial setup) and the absolute local path to your public SSH key.
    * `LocalPaths`: Absolute local paths to your project directories and files.
        * `3xui_Db_Folder`: The local directory containing your pre-configured `[IP_ADDRESS]_x-ui.db` files.
        * `Bandwidth_Api_File`: The local path to your `bandwidth.py` file.
        * `Bots_Db_Dump`: The local path to your `db.dump` file for PostgreSQL.
    * `Cloudflare`: The email and Global API Key for your Cloudflare account, used for SSL certificate generation.
    * `App`: The desired username and password for the non-root application user that the scripts will create.
    * `Database`: Credentials for the PostgreSQL database and user to be created.
    * `BotProjects`: An object where each key represents a bot's name and the value is the absolute local path to that bot's project directory.

---

## Usage

After the `config.json` file has been properly configured, execute the deployment scripts from a local PowerShell terminal.

### Deploying the Main Server

```powershell
./deploy-main.ps1
```

### Deploying the Worker Servers

This script iterates through and deploys to all servers defined in the `WorkerServers` array within the configuration file.

```powershell
./deploy-workers.ps1
```

> **Note**: The `$StartDiscordBots` variable in `deploy-main.ps1` is set to `$false` by default. The script will configure the bot services to run on startup but will not start them immediately after deployment. To activate the bots upon deployment, this variable must be changed to `$true`.