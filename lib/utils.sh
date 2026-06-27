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
}

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-Y}"
    local reply

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

generate_password() {
    local length="${1:-24}"
    local password=""
    local charset_upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    local charset_lower='abcdefghijklmnopqrstuvwxyz'
    local charset_digit='0123456789'
    local charset_symbol='!@#$%^&*-_=+'
    local all="${charset_upper}${charset_lower}${charset_digit}${charset_symbol}"
    local i char

    password+="${charset_upper:$((RANDOM % ${#charset_upper})):1}"
    password+="${charset_lower:$((RANDOM % ${#charset_lower})):1}"
    password+="${charset_digit:$((RANDOM % ${#charset_digit})):1}"
    password+="${charset_symbol:$((RANDOM % ${#charset_symbol})):1}"

    for ((i = 4; i < length; i++)); do
        char="${all:$((RANDOM % ${#all})):1}"
        password+="${char}"
    done

    # Shuffle password characters
    echo "${password}" | fold -w1 | shuf | tr -d '\n'
}

# Docker Compose .env values — single-quoted literals (no shell \$ escaping).
quote_env_value() {
    local value="$1"

    value="${value//\'/\'\'}"
    printf "'%s'" "${value}"
}

# YAML single-quoted string for docker-compose.yml.
yaml_single_quote() {
    local value="$1"

    value="${value//\'/\'\'}"
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
