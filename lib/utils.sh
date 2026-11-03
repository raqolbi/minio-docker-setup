#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared utilities: colors, logging, traps, system helpers.

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Project paths (set by main script before sourcing)
PROJECT_ROOT="${PROJECT_ROOT:-}"

# Container images.
# Upstream minio/minio is archived (no longer maintained, no new Docker images).
# This tool uses PGSTY Silo — a community-maintained MinIO fork, drop-in
# compatible with MINIO_* env vars, the S3 API, and existing .minio.sys data.
# The newest published release is resolved automatically (lib/autoupdate.sh)
# and pinned in .env; there is no hard-coded version to maintain.
# Image used by installs created before MINIO_IMAGE existed in .env.
LEGACY_MINIO_IMAGE="minio/minio:latest"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $*"
}

log_progress() {
    echo -e "${BOLD}>>>${NC} $*"
}

die() {
    log_error "$*"
    exit 1
}

setup_trap() {
    trap 'echo ""; log_warn "Operation cancelled by user (Ctrl+C)."; exit 130' INT TERM
    install_err_trap
}

# Surface unexpected failures instead of exiting silently under 'set -e'.
install_err_trap() {
    trap 'log_error "Unexpected error (exit $?) at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR
}

# Serialize state-changing operations (update, backup, restore, auto-update).
# Locks the project directory itself, so it works for root and normal users.
acquire_operation_lock() {
    [[ "${OPERATION_LOCK_HELD:-false}" == "true" ]] && return 0
    command_exists flock || return 0

    exec 8<"${PROJECT_ROOT}"
    if ! flock -n 8; then
        die "Another setup.sh operation (update/backup/restore) is running. Try again later."
    fi
    OPERATION_LOCK_HELD="true"
}

# When run as root (sudo, systemd timer), hand generated files back to the
# owner of the project directory so later non-root runs can still read them.
restore_project_ownership() {
    local owner path

    [[ "${EUID}" -eq 0 ]] || return 0
    owner="$(stat -c '%u:%g' "${PROJECT_ROOT}" 2>/dev/null)" || return 0
    [[ "${owner}" == "0:0" ]] && return 0

    for path in .env docker-compose.yml secrets backups .update-available; do
        if [[ -e "${PROJECT_ROOT}/${path}" ]]; then
            chown -R "${owner}" "${PROJECT_ROOT}/${path}" 2>/dev/null || true
        fi
    done
}

# Guard destructive operations (rm -rf, mv) on the data path.
assert_safe_data_path() {
    local path="$1"
    local depth

    [[ "${path}" == /* ]] || die "Data path must be absolute: ${path}"
    [[ "${path}" != *:* && "${path}" != *[[:space:]]* ]] || die "Data path must not contain ':' or whitespace: ${path}"

    path="${path%/}"
    depth=$(awk -F/ '{print NF-1}' <<< "${path}")

    case "${path}" in
        ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/lib/docker*)
            die "Refusing to use a system directory as data path: ${path:-/}" ;;
    esac

    [[ "${depth}" -ge 2 ]] || die "Data path is too shallow (use e.g. /opt/minio/data): ${path}"
}

# ASSUME_YES=true (unattended runs) answers every prompt with its default.
ASSUME_YES="${ASSUME_YES:-false}"

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-Y}"
    local reply

    if [[ "${ASSUME_YES}" == "true" ]]; then
        log_info "${prompt} -> ${default} (unattended)"
        [[ "${default}" == "Y" ]]
        return
    fi

    if [[ "${default}" == "Y" ]]; then
        read -r -p "$(echo -e "${prompt} [Y/n]: ")" reply
        reply="${reply:-Y}"
        [[ "${reply}" =~ ^[Yy]$ ]]
    else
        read -r -p "$(echo -e "${prompt} [y/N]: ")" reply
        reply="${reply:-N}"
        [[ "${reply}" =~ ^[Yy]$ ]]
    fi
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local reply

    read -r -p "$(echo -e "${prompt} [${default}]: ")" reply
    echo "${reply:-$default}"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local reply

    if [[ "${ASSUME_YES}" == "true" ]]; then
        log_info "${prompt} -> ${default} (unattended)"
        [[ "${default}" == "Y" ]]
        return
    fi

    if [[ "${default}" == "Y" ]]; then
        read -r -p "$(echo -e "${prompt} (Y/n): ")" reply
        reply="${reply:-Y}"
    else
        read -r -p "$(echo -e "${prompt} (y/N): ")" reply
        reply="${reply:-N}"
    fi

    [[ "${reply}" =~ ^[Yy]$ ]]
}

command_exists() {
    command -v "$1" &>/dev/null
}

get_primary_ip() {
    local ip=""

    if command_exists ip; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    fi

    if [[ -z "${ip}" ]] && command_exists hostname; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
    fi

    echo "${ip}"
}

get_available_disk_mb() {
    local path="$1"
    local parent="${path}"

    while [[ ! -d "${parent}" ]] && [[ "${parent}" != "/" ]]; do
        parent=$(dirname "${parent}")
    done

    df -BM "${parent}" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}'
}

get_total_ram_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0"
}

# Cryptographically secure alphanumeric password from /dev/urandom
# (bash $RANDOM is only 15-bit and not suitable for secrets).
generate_password() {
    local length="${1:-24}"
    local password=""

    while true; do
        password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "${length}" || true)
        if [[ ${#password} -eq ${length} && "${password}" =~ [A-Z] && "${password}" =~ [a-z] && "${password}" =~ [0-9] ]]; then
            printf '%s' "${password}"
            return 0
        fi
    done
}

# Percent-encode a string for use in a URL userinfo component.
url_encode() {
    local LC_ALL=C
    local s="$1" out="" c i

    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) out+="${c}" ;;
            *) printf -v c '%%%02X' "'${c}"; out+="${c}" ;;
        esac
    done

    printf '%s' "${out}"
}

# Host/IP to show users for host-published ports.
display_host() {
    local bind="${MINIO_BIND_ADDRESS:-0.0.0.0}"

    if [[ "${bind}" == "0.0.0.0" ]]; then
        get_primary_ip
    else
        echo "${bind}"
    fi
}

# Address the host itself uses to reach published ports.
host_check_address() {
    local bind="${MINIO_BIND_ADDRESS:-0.0.0.0}"

    if [[ "${bind}" == "0.0.0.0" ]]; then
        echo "127.0.0.1"
    else
        echo "${bind}"
    fi
}

# Docker Compose .env values — single-quoted literals (no shell \$ escaping).
quote_env_value() {
    local value="$1"

    value="${value//\'/\'\'}"
    printf "'%s'" "${value}"
}

# YAML single-quoted string for docker-compose.yml.
#
# Two layers of escaping are required:
#   1. YAML single-quote: a literal ' becomes ''.
#   2. Docker Compose interpolation: Compose still expands $VAR / ${VAR}
#      inside YAML values (even single-quoted), so a literal $ must be
#      written as $$ to survive interpolation.
yaml_single_quote() {
    local value="$1"
    local dollar='$'

    value="${value//\'/\'\'}"
    value="${value//${dollar}/${dollar}${dollar}}"
    printf "'%s'" "${value}"
}

parse_dotenv_value() {
    local value="$1"

    if [[ "${#value}" -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\'\'/\'}"
        printf '%s' "${value}"
        return 0
    fi

    if [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
        printf '%s' "${value}"
        return 0
    fi

    printf '%s' "${value}"
}

load_env_file() {
    local env_file="${PROJECT_ROOT}/.env"
    local line key value

    if [[ ! -f "${env_file}" ]]; then
        die "Configuration not found. Run './setup.sh install' first."
    fi
    if [[ ! -r "${env_file}" ]]; then
        die "Cannot read ${env_file}. Run with sudo or fix ownership."
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" != *"="* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"

        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_warn "Skipping invalid env key: ${key}"
            continue
        fi

        value="$(parse_dotenv_value "${value}")"
        printf -v "${key}" '%s' "${value}"
        export "${key}"
    done < "${env_file}"

    # Defaults for installs created by older versions of this tool.
    MINIO_IMAGE="${MINIO_IMAGE:-${LEGACY_MINIO_IMAGE}}"
    MINIO_BIND_ADDRESS="${MINIO_BIND_ADDRESS:-0.0.0.0}"
    MINIO_NETWORK="${MINIO_NETWORK:-minio-network}"
    export MINIO_IMAGE MINIO_BIND_ADDRESS MINIO_NETWORK

    load_root_password_secret
}

# The secrets file is the single source of truth for the root password.
# Older installs stored it in .env as well; migrate it out of .env.
load_root_password_secret() {
    local secret_file="${PROJECT_ROOT}/secrets/root_password"
    local env_file="${PROJECT_ROOT}/.env"
    local env_password="${MINIO_ROOT_PASSWORD:-}"

    if [[ -f "${secret_file}" ]]; then
        if [[ ! -r "${secret_file}" ]]; then
            die "Cannot read ${secret_file} (owned by $(stat -c %U "${secret_file}" 2>/dev/null || echo another user)). Run with sudo or fix ownership."
        fi
        MINIO_ROOT_PASSWORD="$(<"${secret_file}")"
        if [[ -n "${env_password}" && "${env_password}" != "${MINIO_ROOT_PASSWORD}" ]]; then
            log_warn ".env contains a different MINIO_ROOT_PASSWORD than secrets/root_password; using the secrets file."
        fi
    elif [[ -n "${env_password}" ]]; then
        log_info "Migrating root password from .env to secrets/root_password..."
        mkdir -p "${PROJECT_ROOT}/secrets"
        chmod 700 "${PROJECT_ROOT}/secrets"
        ( umask 077; printf '%s' "${env_password}" > "${secret_file}" )
    fi

    if [[ -n "${env_password}" ]] && grep -q '^MINIO_ROOT_PASSWORD=' "${env_file}" 2>/dev/null; then
        set_env_key_in_file "MINIO_ROOT_PASSWORD" ""
    fi

    export MINIO_ROOT_PASSWORD
}

timestamp() {
    date +"%Y%m%d-%H%M%S"
}

require_root_for_docker_install() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Docker installation requires root privileges. Re-run with sudo."
    fi
}

ensure_project_root() {
    if [[ -z "${PROJECT_ROOT}" ]]; then
        die "PROJECT_ROOT is not set."
    fi
}
