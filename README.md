# MinIO Docker Setup

Production-ready, fully interactive MinIO installer for **Ubuntu Server 22.04+** using Docker Compose v2. No manual editing of `.env` or `docker-compose.yml` is required.

## Features

- Interactive menu — pick an action, no need to remember commands
- CLI mode — pass a command directly for automation
- Automatic Docker installation (optional)
- Auto-generated configuration from templates
- Bind-mount storage (no Docker volumes)
- Optional host port exposure or internal-only Docker network
- Health checks and post-install verification
- Automatic bucket creation via MinIO Client (`mc`)
- Application user with least-privilege IAM policy (ListBucket, GetObject, PutObject, DeleteObject)
- Optional anonymous (public) read access per bucket
- Backup and restore support
- Lifecycle commands: start, stop, restart, logs, status, update

## Requirements

- Ubuntu Server 22.04 or newer
- Docker Compose v2 (`docker compose`)
- `curl`, `openssl`, `systemctl`
- User with permission to run Docker (member of `docker` group) or root/sudo

## Quick Start

```bash
git clone <repository-url> minio-setup
cd minio-setup
chmod +x setup.sh
./setup.sh
```

The interactive menu opens automatically. Select **1) Install MinIO** and follow the prompts. When installation completes, credentials and endpoints are displayed once — save them securely.

### CLI mode

Pass a command directly without opening the menu:

```bash
./setup.sh install
./setup.sh status
./setup.sh backup
```

## Project Structure

```
.
├── setup.sh                # Main entry point (menu + CLI)
├── docker-compose.yml.tpl  # Compose template
├── .env.tpl                # Environment template
├── README.md
└── lib/
    ├── bootstrap.sh        # Library loader
    ├── menu.sh             # Interactive action menu
    ├── commands.sh         # Command dispatcher
    ├── install.sh          # Install entry point
    ├── uninstall.sh        # Uninstall entry point
    ├── ui.sh               # Banners and interactive prompts
    ├── validation.sh       # System and input validation
    ├── docker.sh           # Docker install and container ops
    ├── generator.sh        # Template rendering
    ├── credentials.sh      # Root credential reset (IAM store)
    ├── mc.sh                 # MinIO Client helpers (buckets, IAM, anonymous access)
    ├── access.sh             # Bucket/user access setup and manage menu
    ├── installer.sh          # Install flow, backup, restore
    ├── network.sh          # Docker network management
    └── utils.sh            # Shared utilities
```

Generated at install time (do not edit manually):

- `.env`
- `docker-compose.yml`

## Menu Actions

| # | Action | Description |
|---|--------|-------------|
| 1 | Install | Run interactive MinIO installation |
| 2 | Uninstall | Remove containers, network, and config |
| 3 | Start | Start MinIO |
| 4 | Stop | Stop MinIO |
| 5 | Restart | Restart MinIO |
| 6 | Status | Show container and endpoint status |
| 7 | Logs | Show recent container logs |
| 8 | Update | Pull latest MinIO image and recreate |
| 9 | Backup | Create compressed backup |
| 10 | Restore | Restore from backup archive |
| 11 | Update Public URLs | Set or update MINIO_SERVER_URL / MINIO_BROWSER_REDIRECT_URL |
| 12 | Reset Root Password | Reset root username/password (keeps bucket data) |
| 13 | Diagnose | Troubleshoot login and credential issues |
| 14 | Manage Buckets & User Access | Create buckets, public access, application user, and IAM policy |
| 0 | Exit | Close the menu |

## CLI Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | Open interactive menu |
| `./setup.sh install` | Run interactive installation |
| `./setup.sh uninstall` | Remove containers, network, and config |
| `./setup.sh start` | Start MinIO |
| `./setup.sh stop` | Stop MinIO |
| `./setup.sh restart` | Restart MinIO |
| `./setup.sh logs` | Show recent container logs (`-f` to follow) |
| `./setup.sh diagnose` | Troubleshoot login and credential issues |
| `./setup.sh status` | Show container and endpoint status |
| `./setup.sh update` | Pull latest MinIO image and recreate |
| `./setup.sh update-urls` | Update public API and Console URLs |
| `./setup.sh reset-password` | Reset root username and password |
| `./setup.sh manage-access` | Configure buckets, public access, and application user |
| `./setup.sh backup` | Create compressed backup |
| `./setup.sh restore [file]` | Restore from backup archive |

## Installation Walkthrough

The installer asks for:

1. **Container name** (default: `minio`)
2. **Storage path** (default: `/opt/minio/data`) — created automatically
3. **Expose to host** — if yes, configure API (9000) and Console (9001) ports
4. **Root username** (default: `minioadmin`)
5. **Password** — auto-generated (24+ alphanumeric chars) or manual (letters and numbers, min 24)
6. **Buckets** — create one or more buckets during setup
7. **Public access** — choose which buckets allow anonymous download
8. **Application user** — optional IAM user (default: `app-user`) with least-privilege policy on selected buckets
9. **Public URLs** — optional; for domain + reverse proxy (HTTPS)

It then:

- Validates Ubuntu version, Docker, disk space, RAM, and ports
- Generates `.env` and `docker-compose.yml`
- Creates the `minio-network` Docker network
- Starts MinIO and waits until healthy
- Waits for the API to accept `mc` commands, then creates buckets, IAM policy, and application user (idempotent)
- Configures anonymous read access only on selected public buckets
- Displays a final summary with root admin, application user, bucket access, and endpoints

### Internal-only mode

If you choose **not** to expose ports, MinIO is reachable only on the Docker network `minio-network`. Other containers on that network can connect at:

```
http://<container-name>:9000   # API
http://<container-name>:9001   # Console
```

## Public URLs (Domain / Reverse Proxy)

When MinIO is accessed via a public domain behind Nginx, Traefik, or another reverse proxy with TLS, configure these MinIO environment variables:

| Variable | Purpose | Example |
|----------|---------|---------|
| `MINIO_SERVER_URL` | Public S3 API URL (presigned URLs, hostname) | `https://s3.example.com` |
| `MINIO_BROWSER_REDIRECT_URL` | Public Console URL (login redirect) | `https://console.example.com` |

During **install**, you can set them in the optional step at the end.

For an **existing installation** (including setups created before this feature), update anytime:

```bash
./setup.sh update-urls
```

Or select **11) Update Public URLs** from the menu.

The command updates only the public URL entries in `.env` and refreshes `docker-compose.yml` — **root password and other settings are not modified**. The container is then recreated to apply changes. You can also clear previously set URLs from the same prompt.

**Important:** After setting `MINIO_BROWSER_REDIRECT_URL`, open the Console using that public URL (via your reverse proxy). Logging in at `http://<server-ip>:9001` often fails because MinIO redirects the session to the configured public URL.

## Reset Root Password

If you cannot log in (lost password or `.env` out of sync with MinIO), reset root credentials:

```bash
./setup.sh reset-password
```

Or select **12) Reset Root Password** from the menu.

This will:

1. Stop MinIO
2. Remove the MinIO config store on disk (`.minio.sys/config`) — users, groups, service accounts, and policies (backup created automatically)
3. Set a new root username and password in `.env`
4. Start MinIO and apply the new credentials

**Buckets and object data are preserved.** IAM users, groups, and policies are cleared automatically and must be recreated if needed.

Credentials are written to `secrets/root_password` and mounted via `MINIO_ROOT_PASSWORD_FILE` (MinIO's recommended method), so passwords reach the container exactly as stored in `.env`.

## Update

Pull the latest MinIO image and recreate the container:

```bash
./setup.sh update
```

Or select **8) Update** from the menu.

This preserves your data directory and configuration.

## Backup

Create a timestamped archive containing configuration and data:

```bash
./setup.sh backup
```

Output example:

```
backups/backup-20250627-143022.tar.gz
```

Contents:

- `config/docker-compose.yml`
- `config/.env`
- `data.tar` (MinIO data directory)

## Restore

Restore from a backup archive:

```bash
./setup.sh restore backups/backup-20250627-143022.tar.gz
```

Or select **10) Restore** from the menu (you will be prompted for the archive path).

Restore stops MinIO, replaces configuration and data, then restarts and verifies health.

## Uninstall

```bash
./setup.sh uninstall
```

Or select **2) Uninstall** from the menu.

You will be prompted to:

1. Confirm removal of containers and generated config
2. Optionally delete the data directory

Templates and setup scripts remain in the project directory.

## Troubleshooting

### Docker permission denied

Add your user to the `docker` group and re-login:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

### Port already in use

Choose different API/Console ports during installation, or free the port:

```bash
sudo ss -tulpn | grep :9000
```

### Container unhealthy

Check logs:

```bash
./setup.sh logs
```

Verify data directory permissions:

```bash
ls -la /opt/minio/data
```

Restart:

```bash
./setup.sh restart
```

### Cannot reach API or Console

- Confirm ports are exposed if accessing from outside Docker
- Check firewall rules:

```bash
sudo ufw status
sudo ufw allow 9000/tcp
sudo ufw allow 9001/tcp
```

- Verify status:

```bash
./setup.sh status
```

Credentials are written to `secrets/root_password` and mounted via `MINIO_ROOT_PASSWORD_FILE` (MinIO's recommended method), so the exact password reaches the container without Docker Compose interpolation issues.

### Console login fails (invalid login)

Run diagnostics first:

```bash
./setup.sh diagnose
```

This checks container status, tests API login with your `.env` credentials, shows the correct Console URL, and prints recent logs.

Common causes:

1. **Wrong Console URL** — If `MINIO_BROWSER_REDIRECT_URL` is set, log in via that public URL, **not** `http://<ip>:9001`.
2. **Stale IAM credentials** — Reinstalling over existing data without IAM reset leaves old passwords active. Run `./setup.sh reset-password`.
3. **Container not running** — `./setup.sh logs` showed nothing because the container was stopped. Run `./setup.sh start` then `./setup.sh diagnose`.
4. **Outdated config** — Pull latest code, then `./setup.sh reset-password` to migrate to `MINIO_ROOT_PASSWORD_FILE`.

### Console login fails after setting public URLs

This is usually **not** a password change. MinIO stores root credentials on first install in the data volume; `update-urls` does not reset them.

Common causes:

1. **Wrong URL** — Use the public Console URL (`MINIO_BROWSER_REDIRECT_URL`), not `http://<ip>:9001`, after redirect is configured.
2. **Reverse proxy** — Ensure your proxy forwards WebSocket and cookies to MinIO Console correctly.
3. **Outdated installer** — Pull the latest code and run `./setup.sh reset-password`.

To clear public URLs and restore direct IP access:

```bash
./setup.sh update-urls
# Choose to clear existing public URLs when prompted
```

If login still fails on both IP and public URL, reset credentials:

```bash
./setup.sh reset-password
```

The reset recreates the Docker container so new credentials from `.env` are applied. If `MINIO_BROWSER_REDIRECT_URL` is set, log in via that public URL — not `http://<ip>:9001`.

### Bucket or access setup failed

Ensure MinIO is healthy, then re-run the access wizard:

```bash
./setup.sh manage-access
```

Or check status and logs:

```bash
./setup.sh status
./setup.sh logs
```

### ShellCheck

Validate scripts locally:

```bash
shellcheck setup.sh lib/*.sh
```

## Manage Buckets & User Access

After installation, use menu **14) Manage Buckets & User Access** or:

```bash
./setup.sh manage-access
```

Sub-menu options:

1. **Configure buckets and public access** — add buckets and set anonymous download
2. **Create or update application user** — set username/password and attach IAM policy
3. **Apply full access setup** — run the complete interactive wizard (same as install)
4. **Show current access summary** — display configured buckets and endpoints

CLI shortcuts:

```bash
./setup.sh manage-access buckets   # buckets + public access only
./setup.sh manage-access user      # application user only
./setup.sh manage-access full      # full wizard
./setup.sh manage-access summary   # print summary
```

The application user receives a generated IAM policy with only `ListBucket`, `GetObject`, `PutObject`, and `DeleteObject` on the configured buckets. Operations are idempotent — re-running setup updates policies and users without failing on existing resources.

Application passwords are stored in `secrets/app_password` (not in `.env`).

## Security Notes

- `.env` is written with mode `600` and contains the root password
- Use strong passwords; manual entry requires at least 24 alphanumeric characters (uppercase, lowercase, and numbers)
- For production, place MinIO behind a reverse proxy with TLS
- Restrict host port exposure with firewall rules when enabled
- Back up `.env` and data regularly

## License

MIT — use freely in your infrastructure.
