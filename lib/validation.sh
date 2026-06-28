#!/usr/bin/env bash
# Validation helpers for system, ports, paths, and credentials.

validate_ubuntu_version() {
    log_step "Checking Ubuntu version..."

    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS. Ubuntu Server 22.04+ is required."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ${ID:-unknown}. Ubuntu Server 22.04+ is required."
    fi

    local version_id="${VERSION_ID:-0}"
    local major="${version_id%%.*}"

    if [[ "${major}" -lt 22 ]]; then
        die "Ubuntu ${version_id} detected. Ubuntu Server 22.04+ is required."
    fi

    log_success "Ubuntu ${version_id} detected."
}

validate_dependencies() {
    log_step "Checking dependencies..."

    local missing=()
    local dep

    for dep in curl openssl systemctl; do
        if ! command_exists "${dep}"; then
            missing+=("${dep}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required dependencies: ${missing[*]}. Install them with: sudo apt-get install -y ${missing[*]}"
    fi

    log_success "Required dependencies present (curl, openssl, systemctl)."
}

validate_docker_compose() {
    log_step "Checking Docker Compose..."

    if docker compose version &>/dev/null; then
        local version
        version=$(docker compose version --short 2>/dev/null || docker compose version)
        log_success "Docker Compose v2 available (${version})."
        return 0
    fi

    die "Docker Compose v2 is not installed. Install Docker Engine with Compose plugin."
}

validate_docker_running() {
    log_step "Checking Docker daemon..."

    if ! command_exists docker; then
        return 1
    fi

    if ! docker info &>/dev/null; then
        die "Docker is installed but not running. Start it with: sudo systemctl start docker"
    fi

    log_success "Docker daemon is running."
}

validate_port() {
    local port="$1"

    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        log_error "Port must be numeric: ${port}"
        return 1
    fi

    if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
        log_error "Port out of range (1-65535): ${port}"
        return 1
    fi

    if is_port_in_use "${port}"; then
        log_error "Port ${port} is already in use."
        return 1
    fi

    return 0
}

is_port_in_use() {
    local port="$1"

    if command_exists ss; then
        ss -tuln 2>/dev/null | grep -q ":${port} "
        return $?
    fi

    if command_exists netstat; then
        netstat -tuln 2>/dev/null | grep -q ":${port} "
        return $?
    fi

    if command_exists lsof; then
        lsof -i ":${port}" -sTCP:LISTEN &>/dev/null
        return $?
    fi

    return 1
}

validate_password() {
    local password="$1"

    if [[ ${#password} -lt 24 ]]; then
        log_error "Password must be at least 24 characters."
        return 1
    fi

    if [[ ! "${password}" =~ [A-Z] ]]; then
        log_error "Password must contain at least one uppercase letter."
        return 1
    fi

    if [[ ! "${password}" =~ [a-z] ]]; then
        log_error "Password must contain at least one lowercase letter."
        return 1
    fi

    if [[ ! "${password}" =~ [0-9] ]]; then
        log_error "Password must contain at least one number."
        return 1
    fi

    if [[ ! "${password}" =~ ^[A-Za-z0-9]+$ ]]; then
        log_error "Password must contain letters and numbers only (no symbols)."
        return 1
    fi

    return 0
}

validate_storage_path() {
    local path="$1"

    log_step "Validating storage path: ${path}"

    if [[ -e "${path}" && ! -d "${path}" ]]; then
        die "Storage path exists but is not a directory: ${path}"
    fi

    local parent
    parent=$(dirname "${path}")

    if [[ ! -d "${parent}" ]]; then
        log_info "Creating parent directory: ${parent}"
        if [[ "${EUID}" -eq 0 ]]; then
            mkdir -p "${parent}" || die "Failed to create parent directory: ${parent}"
        else
            sudo mkdir -p "${parent}" || die "Failed to create parent directory: ${parent}"
        fi
    fi

    if [[ ! -d "${path}" ]]; then
        log_info "Creating storage directory: ${path}"
        if [[ "${EUID}" -eq 0 ]]; then
            mkdir -p "${path}" || die "Failed to create storage directory: ${path}"
        else
            sudo mkdir -p "${path}" || die "Failed to create storage directory: ${path}"
        fi
    fi

    if [[ ! -w "${path}" ]]; then
        if [[ "${EUID}" -eq 0 ]]; then
            chmod 755 "${path}" || die "Storage path is not writable: ${path}"
        else
            sudo chmod 755 "${path}" || die "Storage path is not writable: ${path}"
        fi
    fi

    log_success "Storage path is valid and writable."
}

validate_disk_space() {
    local path="$1"
    local min_mb="${2:-1024}"

    log_step "Checking available disk space..."

    local available
    available=$(get_available_disk_mb "${path}")

    if [[ -z "${available}" || "${available}" -lt "${min_mb}" ]]; then
        die "Insufficient disk space at ${path}. At least ${min_mb}MB required."
    fi

    log_success "Disk space OK (${available}MB available)."
}

validate_ram() {
    local min_mb="${1:-512}"

    log_step "Checking system RAM..."

    local ram
    ram=$(get_total_ram_mb)

    if [[ -z "${ram}" || "${ram}" -lt "${min_mb}" ]]; then
        log_warn "Low RAM detected (${ram}MB). MinIO recommends at least ${min_mb}MB."
    else
        log_success "RAM OK (${ram}MB total)."
    fi
}

validate_exposed_ports() {
    if [[ "${MINIO_EXPOSE_PORTS}" != "true" ]]; then
        log_info "Ports not exposed to host; skipping port availability checks."
        return 0
    fi

    log_step "Validating port availability..."

    if ! validate_port "${MINIO_API_PORT}"; then
        die "API port ${MINIO_API_PORT} is invalid or in use."
    fi

    if ! validate_port "${MINIO_CONSOLE_PORT}"; then
        die "Console port ${MINIO_CONSOLE_PORT} is invalid or in use."
    fi

    log_success "Ports ${MINIO_API_PORT} and ${MINIO_CONSOLE_PORT} are available."
}

validate_public_url() {
    local url="$1"
    local label="$2"

    if [[ -z "${url}" ]]; then
        return 0
    fi

    if [[ ! "${url}" =~ ^https?://[^[:space:]/]+ ]]; then
        log_error "${label} must start with http:// or https:// (example: https://s3.example.com)"
        return 1
    fi

    return 0
}

validate_public_urls_pair() {
    local require_both="${1:-false}"

    if [[ -z "${MINIO_SERVER_URL}" && -z "${MINIO_BROWSER_REDIRECT_URL}" ]]; then
        return 0
    fi

    if ! validate_public_url "${MINIO_SERVER_URL}" "Public API URL (MINIO_SERVER_URL)"; then
        return 1
    fi

    if ! validate_public_url "${MINIO_BROWSER_REDIRECT_URL}" "Public Console URL (MINIO_BROWSER_REDIRECT_URL)"; then
        return 1
    fi

    if [[ "${require_both}" == "true" ]]; then
        if [[ -z "${MINIO_SERVER_URL}" || -z "${MINIO_BROWSER_REDIRECT_URL}" ]]; then
            log_error "Both public API URL and Console URL are required when enabling public URL configuration."
            return 1
        fi
    fi

    return 0
}

validate_bucket_name() {
    local name="$1"

    if [[ ${#name} -lt 3 || ${#name} -gt 63 ]]; then
        log_error "Bucket name must be 3–63 characters: ${name}"
        return 1
    fi

    if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        log_error "Invalid bucket name '${name}'. Use lowercase letters, numbers, dots, and hyphens."
        return 1
    fi

    if [[ "${name}" =~ \.\. ]]; then
        log_error "Bucket name cannot contain consecutive dots: ${name}"
        return 1
    fi

    if [[ "${name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Bucket name cannot look like an IP address: ${name}"
        return 1
    fi

    return 0
}

validate_app_username() {
    local user="$1"

    if [[ ${#user} -lt 3 ]]; then
        log_error "Application username must be at least 3 characters."
        return 1
    fi

    if [[ ! "${user}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_error "Invalid application username. Use alphanumeric characters, dots, hyphens, or underscores."
        return 1
    fi

    if [[ "${user}" == "${MINIO_ROOT_USER:-}" ]]; then
        log_error "Application username must differ from the root admin username."
        return 1
    fi

    return 0
}

validate_root_username() {
    local user="$1"

    if [[ ${#user} -lt 3 ]]; then
        log_error "Root username must be at least 3 characters."
        return 1
    fi

    if [[ ! "${user}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_error "Invalid root username. Use alphanumeric characters, dots, hyphens, or underscores."
        return 1
    fi

    return 0
}

validate_container_name() {
    local name="$1"

    if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        die "Invalid container name: ${name}. Use alphanumeric characters, dots, hyphens, or underscores."
    fi
}

run_pre_install_validation() {
    validate_ubuntu_version
    validate_dependencies
    validate_docker_compose
    validate_docker_running
    validate_container_name "${MINIO_CONTAINER_NAME}"
    validate_storage_path "${MINIO_DATA_PATH}"
    validate_disk_space "${MINIO_DATA_PATH}" 1024
    validate_ram 512
    validate_exposed_ports
}
