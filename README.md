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
    ├── installer.sh        # Install flow, backup, restore, bucket
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
| 7 | Logs | Follow container logs |
| 8 | Update | Pull latest MinIO image and recreate |
| 9 | Backup | Create compressed backup |
| 10 | Restore | Restore from backup archive |
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
| `./setup.sh logs` | Follow container logs |
| `./setup.sh status` | Show container and endpoint status |
| `./setup.sh update` | Pull latest MinIO image and recreate |
| `./setup.sh backup` | Create compressed backup |
| `./setup.sh restore [file]` | Restore from backup archive |

## Installation Walkthrough

The installer asks for:

1. **Container name** (default: `minio`)
2. **Storage path** (default: `/opt/minio/data`) — created automatically
3. **Expose to host** — if yes, configure API (9000) and Console (9001) ports
4. **Root username** (default: `minioadmin`)
5. **Password** — auto-generated (24+ chars) or manual
6. **Default bucket** — optional (default name: `storage`)

It then:

- Validates Ubuntu version, Docker, disk space, RAM, and ports
- Generates `.env` and `docker-compose.yml`
- Creates the `minio-network` Docker network
- Starts MinIO and waits until healthy
- Creates the bucket if requested
- Displays a final summary with endpoints and credentials

### Internal-only mode

If you choose **not** to expose ports, MinIO is reachable only on the Docker network `minio-network`. Other containers on that network can connect at:

```
http://<container-name>:9000   # API
http://<container-name>:9001   # Console
```

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

### Bucket creation failed

Ensure MinIO is healthy, then create manually:

```bash
docker run --rm --network minio-network minio/mc:latest \
  alias set local http://minio:9000 minioadmin 'YOUR_PASSWORD'

docker run --rm --network minio-network minio/mc:latest \
  mb local/storage
```

### ShellCheck

Validate scripts locally:

```bash
shellcheck setup.sh lib/*.sh
```

## Security Notes

- `.env` is written with mode `600` and contains the root password
- Use strong passwords; the installer enforces complexity for manual entry
- For production, place MinIO behind a reverse proxy with TLS
- Restrict host port exposure with firewall rules when enabled
- Back up `.env` and data regularly

## License

MIT — use freely in your infrastructure.
