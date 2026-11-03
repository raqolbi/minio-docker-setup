# MinIO Docker Setup

Production-ready, fully interactive MinIO installer for **Ubuntu 22.04+ / Debian 12+** using Docker Compose v2. No manual editing of `.env` or `docker-compose.yml` is required.

## Server image (important)

The upstream `minio/minio` repository is **archived and no longer maintained**, and upstream stopped publishing community Docker images (the last one is `minio/minio:RELEASE.2025-09-07T16-13-09Z`). Using `minio/minio:latest` means running a frozen build that will never receive security fixes.

This installer therefore uses **[PGSTY Silo](https://github.com/pgsty/silo)** (`docker.io/pgsty/silo`), an AGPLv3 community-maintained MinIO fork with regular releases, security fixes and the full web Console. It is drop-in compatible: same `MINIO_*` environment variables, S3 API, `/minio/*` routes and `.minio.sys` on-disk data, so existing MinIO data directories can be reused.

Fully automatic, no hard-coded version: the installer looks up the **newest stable Silo release** on GitHub, verifies that its image is published on Docker Hub (if the newest release has no image yet, it takes the previous one), and pins that exact tag. If GitHub or Docker Hub cannot be reached, installation stops before changing anything, and `update` keeps the current version running.

The image is always **pinned** and stored in `.env` as `MINIO_IMAGE`; nothing pulls `:latest`. Existing installs that predate this setting keep `minio/minio:latest` until you run `./setup.sh update`, which moves them to Silo in place.

## Checking for new Silo releases / auto-update

```bash
./setup.sh check-update          # is a newer Silo release available?
./setup.sh update                # upgrade to the latest release (backup + rollback)
./setup.sh auto-update enable    # schedule automatic checks (systemd timer)
./setup.sh auto-update status
./setup.sh auto-update disable
```

Menu: **15) Check for Silo Update**, **16) Auto-Update Settings**.

`auto-update enable` installs a systemd timer (`minio-setup-update-<container>.timer`, default weekly `Sun 03:30` with up to 30 min random delay) in one of two modes:

| Mode | What happens |
|------|--------------|
| `check` (recommended) | Detects a new release, shows it in `status`, and sends an optional webhook notification. You upgrade manually with `./setup.sh update` after reading the release notes. |
| `apply` | Backs up (MinIO is stopped during the data copy), pulls the new image, recreates the container, and **rolls back automatically** if it does not become healthy. Keeps the last 3 backups (`AUTO_UPDATE_KEEP_BACKUPS` in `.env`). Causes brief downtime. |

Notes:

- Only stable GitHub releases are considered (no drafts or pre-releases), and only when the image is actually published.
- Updates never downgrade implicitly.
- Webhook notifications send `{"text": ..., "content": ...}`, which works with Slack, Mattermost, Google Chat and Discord incoming webhooks.
- Logs: `journalctl -u minio-setup-update-<container>.service`
- The server needs outbound HTTPS to `api.github.com` and Docker Hub.

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
- `mc` runs inside the MinIO container — no host `mc` download, no helper images, credentials never on the host command line

## Requirements

- Ubuntu 22.04+ or Debian 12+
- Docker Compose v2 (`docker compose`)
- `curl`, `tar`, `systemctl`
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
    ├── credentials.sh      # Root credentials, in-container mc runner
    ├── mc.sh                 # MinIO Client helpers (buckets, IAM, anonymous access)
    ├── autoupdate.sh         # Silo release check + scheduled auto-update (systemd timer)
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
| 8 | Update Image | Upgrade to the latest Silo release, with backup and rollback |
| 9 | Backup | Create compressed backup |
| 10 | Restore | Restore from backup archive |
| 11 | Update Public URLs | Set or update MINIO_SERVER_URL / MINIO_BROWSER_REDIRECT_URL |
| 12 | Reset Root Password | Reset root username/password (keeps bucket data) |
| 13 | Diagnose | Troubleshoot login and credential issues |
| 14 | Manage Buckets & User Access | Create buckets, public access, application user, and IAM policy |
| 15 | Check for Silo Update | Compare running image with the latest Silo release |
| 16 | Auto-Update Settings | Enable/disable scheduled update check or apply |
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
| `./setup.sh update [image]` | Upgrade to the latest Silo release (or the given image) |
| `./setup.sh check-update` | Check for a newer Silo release |
| `./setup.sh auto-update [enable\|disable\|status]` | Configure scheduled update check/apply |
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

1. Write the new password to `secrets/root_password` and the username to `.env`
2. Recreate the container (MinIO reads root credentials from the environment on every start)
3. Verify the new credentials against the API

**Buckets, objects, IAM users, policies and access keys are preserved.** Changing the root password does not require wiping the IAM store on current MinIO/Silo versions.

Only if verification fails on data written by a very old MinIO version (config encrypted with the previous root credentials) does the command offer a **last-resort** IAM reset. That deletes all IAM users/policies/access keys (a backup copy of `.minio.sys/config` is kept) and re-creates the configured application user afterwards. It defaults to **No**.

## Update image

```bash
./setup.sh update                                   # latest Silo release
./setup.sh update docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z   # explicit tag
```

Or select **8) Update Image** from the menu.

The command offers a backup first, pulls the new image (nothing changes if the pull fails), updates `MINIO_IMAGE` in `.env`, recreates the container and waits for it to become healthy. If it does not, it offers to roll back to the previous image. Data and configuration are preserved.

Moving an existing `minio/minio` install to Silo is an in-place upgrade.

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
- `secrets/` (root and application passwords)
- `data.tar` (MinIO data directory)

If MinIO is running, the command offers to stop it during the data copy (short downtime) so the snapshot is consistent, then starts it again. The `backups/` directory is `700` and archives are `600` — they contain credentials, so store them securely, preferably off the server.

## Restore

Restore from a backup archive:

```bash
./setup.sh restore backups/backup-20250627-143022.tar.gz
```

Or select **10) Restore** from the menu (you will be prompted for the archive path).

Restore also works on a **fresh server** (no existing `.env`): copy the project and the archive, then run `./setup.sh restore <archive>` — configuration, secrets and data all come from the backup.

Restore first validates the archive (readable, no absolute or `..` paths), checks free space, and extracts data into a staging directory while MinIO keeps running. Only then does it stop MinIO, swap the data in, and apply the configuration and secrets. Any failure before that point leaves the installation untouched. The previous data directory is kept as `<data-path>.pre-restore-<timestamp>` — delete it once you have verified the restore.

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

The healthcheck uses `mc ready local` (bundled in the Silo image). Older installs used `curl`, which the image does not contain, so they always reported `unhealthy`; run any command that regenerates the compose file (e.g. `./setup.sh update`) to fix it.

### Cannot reach API or Console

- Confirm ports are exposed if accessing from outside Docker
- Check the bind address (`MINIO_BIND_ADDRESS`): `127.0.0.1` only accepts connections from the host itself
- **Docker-published ports bypass UFW.** `ufw deny 9000` does not block a port published on `0.0.0.0`. Bind to `127.0.0.1` behind a reverse proxy, or filter in the `DOCKER-USER` iptables chain.
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

This checks the image, clock (NTP) sync, container status, tests API login with the configured credentials, checks that the server can reach its own public API URL, shows the correct Console URL, and prints recent logs. The password is not printed unless you pass `--show-password`.

Common causes:

1. **Wrong Console URL** — If `MINIO_BROWSER_REDIRECT_URL` is set, log in via that public URL, **not** `http://<ip>:9001`.
2. **Public URL not reachable from the server** — With `MINIO_SERVER_URL` set, the Console calls that URL from inside the container. Without hairpin NAT / split DNS, login fails even with correct credentials. `diagnose` reports this.
3. **Container not running** — `./setup.sh logs` showed nothing because the container was stopped. Run `./setup.sh start` then `./setup.sh diagnose`.
4. **Outdated config** — Pull latest code, then `./setup.sh reset-password` to migrate to `MINIO_ROOT_PASSWORD_FILE`.

### Console login fails after setting public URLs

This is usually **not** a password change; `update-urls` does not touch credentials.

Common causes:

1. **Wrong URL** — Use the public Console URL (`MINIO_BROWSER_REDIRECT_URL`), not `http://<ip>:9001`, after redirect is configured.
2. **Reverse proxy** — Ensure your proxy forwards WebSocket and cookies to MinIO Console correctly.
3. **Hairpin / DNS** — The server itself must be able to reach `MINIO_SERVER_URL` (see `./setup.sh diagnose`).
4. **Outdated installer** — Pull the latest code and run `./setup.sh reset-password`.

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

The application user receives a generated IAM policy limited to the configured buckets: `ListBucket`, `GetBucketLocation`, `ListBucketMultipartUploads`, `GetObject`, `PutObject`, `DeleteObject`, `AbortMultipartUpload`, `ListMultipartUploadParts` (the multipart actions are needed by S3 SDKs for large uploads). Public buckets are set to anonymous **download (read-only)**; a bucket found with anonymous write (`public`/`upload`) is corrected. Operations are idempotent — re-running setup updates policies and users without failing on existing resources.

Application passwords are stored in `secrets/app_password` (not in `.env`).

## Security Notes

- The root password lives only in `secrets/root_password` (dir `700`, file `600`), mounted via `MINIO_ROOT_PASSWORD_FILE`. Older installs that kept it in `.env` are migrated automatically on the next command.
- Generated passwords come from `/dev/urandom` (24 alphanumeric characters); manual entry requires at least 24 alphanumeric characters (uppercase, lowercase, and numbers)
- `mc` commands run inside the container; credentials are passed over stdin, never as host process arguments or in a persistent `~/.mc` config
- For production, place MinIO behind a reverse proxy with TLS and bind host ports to `127.0.0.1`
- Docker-published ports on `0.0.0.0` bypass UFW
- Keep the clock NTP-synchronized (S3 rejects requests with >15 min skew)
- Container logs are capped (json-file, 5 × 10 MB)
- This is a single-node, single-drive deployment: no erasure coding or bitrot healing. Keep regular off-server backups.
- Back up regularly; backup archives contain credentials
- New data directories are created with mode `700` (objects are plain files on disk); the data path must be absolute and cannot be a system directory such as `/`, `/opt` or `/var`
- The installer refuses a data path already mounted by another container (two servers on one directory corrupt data)
- Update, backup, restore and the auto-update timer take a lock, so they never run concurrently
- `auto-update enable` refuses to install the root-run timer if the project files are writable by other users

## License

MIT — use freely in your infrastructure.
