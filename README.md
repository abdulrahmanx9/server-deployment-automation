# Server & Discord Bot Deployment Scripts

This project contains a set of PowerShell scripts designed to automate the deployment of server environments for a Discord bot application. It handles setting up a "main" server with a database and bots, as well as multiple "worker" servers.

## Features

-   **Automated Server Setup**: Updates the system, installs dependencies like Python 3.12 and PostgreSQL.
-   **User Management**: Creates a dedicated application user with sudo privileges and deploys an SSH key for passwordless access.
-   **3x-ui Panel Deployment**: Installs the 3x-ui panel, restores its database from a backup, and automatically configures SSL using Cloudflare.
-   **Bandwidth API**: Deploys a FastAPI-based bandwidth monitoring API as a systemd service.
-   **PostgreSQL Automation**: Sets up a PostgreSQL database and user, and restores a database from a dump file.
-   **Discord Bot Deployment**: Deploys multiple Discord bots, sets up their Python virtual environments, and configures them to run as systemd services.

## Prerequisites

1.  A Windows machine with PowerShell.
2.  `ssh` and `scp` available in your PowerShell terminal (usually included in modern Windows).
3.  A personal SSH public key (e.g., `id_ed25519.pub`).
4.  All required local files (3x-ui databases, bot database dump, bot project files) available on your machine.

## Configuration

1.  Copy the `config.example.json` file and rename it to `config.json`.
2.  Open `config.json` and fill in all the required values, including server IPs, API keys, passwords, and local file paths.
3.  **DO NOT commit the `config.json` file to version control.** It is already listed in the `.gitignore` file to prevent this.

## Usage

Once the `config.json` file is correctly configured, you can run the deployment scripts.

### Deploying the Main Server

```powershell
.\deploy-main.ps1