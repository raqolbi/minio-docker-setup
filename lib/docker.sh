#!/usr/bin/env bash
# Docker installation and container management.

install_docker() {
    log_step "Installing Docker Engine..."

    require_root_for_docker_install

    local distro codename
    # shellcheck disable=SC1091
    distro="$(. /etc/os-release && echo "${ID}")"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    case "${distro}" in
        ubuntu|debian) ;;
        *) die "Automatic Docker installation supports Ubuntu and Debian only (detected: ${distro})." ;;
    esac

    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    log_success "Docker Engine installed and started."
}

ensure_docker_available() {
    log_step "Checking Docker installation..."

    if command_exists docker; then
        validate_docker_running
        return 0
    fi

    log_warn "Docker is not installed."

    if ! confirm "Install Docker now?" "Y"; then
        die "Docker is required. Installation aborted."
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        log_info "Elevating privileges to install Docker..."
        sudo bash -c "source '${PROJECT_ROOT}/lib/utils.sh' && source '${PROJECT_ROOT}/lib/docker.sh' && install_docker"
    else
        install_docker
    fi
    validate_docker_running
}

compose_cmd() {
    docker compose -f "${PROJECT_ROOT}/docker-compose.yml" --env-file "${PROJECT_ROOT}/.env" "$@"
}

compose_recreate() {
    log_step "Recreating container to apply updated environment..."
    compose_cmd up -d --force-recreate --remove-orphans
}

wait_for_healthy() {
    local container_name="$1"
    local timeout="${2:-180}"
    local elapsed=0
    local status=""

    log_step "Waiting for container to become healthy (timeout: ${timeout}s)..."

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "${container_name}" 2>/dev/null || echo "missing")

        case "${status}" in
            healthy)
                log_success "Container is healthy."
                return 0
                ;;
            running)
                if docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null | grep -q true; then
                    if check_api_internal; then
                        log_success "Container is running and API is reachable."
                        return 0
                    fi
                fi
                ;;
            unhealthy)
                if check_api_internal; then
                    log_warn "Docker health probe reports unhealthy, but the MinIO API is reachable."
                    log_warn "The image may not bundle 'mc' (used by the healthcheck)."
                    return 0
                fi
                log_error "Container reported unhealthy status."
                compose_cmd logs --tail=50
                return 1
                ;;
            missing)
                log_error "Container not found: ${container_name}"
                return 1
                ;;
        esac

        sleep 5
        elapsed=$((elapsed + 5))
        log_info "Health status: ${status} (${elapsed}s elapsed)..."
    done

    log_error "Timed out waiting for container health."
    compose_cmd logs --tail=30 2>/dev/null || true
    return 1
}

# Probe an HTTP URL from inside the MinIO container (no extra helper images).
# Uses curl when the image has it (pgsty/silo does); otherwise falls back to
# Docker's health status (healthcheck uses mc ready).
container_http_ok() {
    local url="$1"
    local rc=0

    docker exec "${MINIO_CONTAINER_NAME}" sh -c \
        'command -v curl >/dev/null 2>&1 || exit 99; curl -fsS --max-time 5 -o /dev/null "$1"' sh "${url}" \
        &>/dev/null || rc=$?

    if [[ "${rc}" -eq 99 ]]; then
        [[ "$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
            "${MINIO_CONTAINER_NAME}" 2>/dev/null)" == "healthy" ]]
        return $?
    fi

    return "${rc}"
}

check_api_internal() {
    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        curl -fsS --max-time 5 "http://$(host_check_address):${MINIO_API_PORT}/minio/health/live" &>/dev/null
        return $?
    fi

    container_http_ok "http://127.0.0.1:9000/minio/health/live"
}

verify_container_running() {
    local container_name="$1"

    log_step "Verifying container is running..."

    if docker ps --format '{{.Names}}' | grep -qx "${container_name}"; then
        log_success "Container '${container_name}' is running."
        return 0
    fi

    log_error "Container '${container_name}' is not running."
    return 1
}

verify_docker_health() {
    local container_name="$1"

    log_step "Checking Docker health status..."

    local health
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "${container_name}" 2>/dev/null || echo "missing")

    case "${health}" in
        healthy)
            log_success "Docker health check: healthy."
            return 0
            ;;
        starting)
            log_warn "Docker health check: starting (may still be initializing)."
            return 0
            ;;
        none)
            log_warn "No Docker health check configured; verifying API instead."
            return 0
            ;;
        *)
            log_error "Docker health check: ${health}"
            return 1
            ;;
    esac
}

verify_api_reachable() {
    log_step "Verifying MinIO API is reachable..."

    if check_api_internal; then
        log_success "MinIO API is reachable."
        return 0
    fi

    log_error "MinIO API is not reachable."
    return 1
}

verify_console_reachable() {
    log_step "Verifying MinIO Console is reachable..."

    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        local code
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://$(host_check_address):${MINIO_CONSOLE_PORT}/" 2>/dev/null || echo "000")

        if [[ "${code}" =~ ^[23] ]]; then
            log_success "MinIO Console is reachable (HTTP ${code})."
            return 0
        fi

        log_error "MinIO Console is not reachable (HTTP ${code})."
        return 1
    fi

    if container_http_ok "http://127.0.0.1:9001/"; then
        log_success "MinIO Console is reachable (internal)."
        return 0
    fi

    log_error "MinIO Console is not reachable."
    return 1
}

run_health_checks() {
    local failed=0

    verify_container_running "${MINIO_CONTAINER_NAME}" || failed=1
    verify_docker_health "${MINIO_CONTAINER_NAME}" || failed=1
    verify_api_reachable || failed=1
    verify_console_reachable || failed=1

    if [[ "${failed}" -eq 0 ]]; then
        log_success "All health checks passed."
        return 0
    fi

    log_error "One or more health checks failed."
    return 1
}

cmd_start() {
    load_env_file
    log_progress "Starting MinIO..."
    compose_cmd up -d
    wait_for_healthy "${MINIO_CONTAINER_NAME}"
    log_success "MinIO started."
}

cmd_stop() {
    load_env_file
    log_progress "Stopping MinIO..."
    compose_cmd stop
    log_success "MinIO stopped."
}

cmd_restart() {
    load_env_file
    log_progress "Restarting MinIO..."
    compose_cmd restart
    wait_for_healthy "${MINIO_CONTAINER_NAME}"
    log_success "MinIO restarted."
}

cmd_logs() {
    local follow=false

    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        follow=true
    fi

    load_env_file

    if ! docker ps --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"; then
        log_warn "Container '${MINIO_CONTAINER_NAME}' is not running."
        log_info "Showing last available logs (if any)..."
    fi

    if [[ "${follow}" == "true" ]]; then
        compose_cmd logs -f --tail=100
    else
        compose_cmd logs --tail=100
    fi
}

cmd_status() {
    load_env_file

    echo ""
    echo -e "${BOLD}MinIO Status${NC}"
    echo "--------------------------------"

    compose_cmd ps

    echo ""
    if docker ps --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"; then
        local health
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' \
            "${MINIO_CONTAINER_NAME}" 2>/dev/null)
        echo -e "Health: ${health}"

        echo "Image:  ${MINIO_IMAGE}"
        if [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
            echo "API:     http://$(display_host):${MINIO_API_PORT}"
            echo "Console: http://$(display_host):${MINIO_CONSOLE_PORT}"
        else
            echo "API/Console: internal Docker network only"
        fi

        if [[ -f "${PROJECT_ROOT}/.update-available" ]]; then
            echo -e "${YELLOW}Update available: $(<"${PROJECT_ROOT}/.update-available") (./setup.sh update)${NC}"
        fi

        if [[ -n "${MINIO_SERVER_URL:-}" || -n "${MINIO_BROWSER_REDIRECT_URL:-}" ]]; then
            echo "Public API URL:     ${MINIO_SERVER_URL:-not set}"
            echo "Public Console URL: ${MINIO_BROWSER_REDIRECT_URL:-not set}"
        fi
    else
        echo "Container is not running."
    fi
    echo ""
}

image_is_unpinned() {
    local image="$1"
    local last="${image##*/}"

    [[ "${image}" != *"@sha256:"* && ( "${last}" != *":"* || "${last}" == *":latest" ) ]]
}

# Upgrade the server image (default: the pinned Silo release). Image is pinned
# in .env (MINIO_IMAGE); nothing ever pulls ':latest' implicitly.
cmd_update() {
    local new_image="${1:-}"
    local old_image

    load_env_file
    acquire_operation_lock
    old_image="${MINIO_IMAGE}"

    echo ""
    echo -e "${BOLD}Current image:${NC} ${old_image}"
    echo ""

    # Default target: newest published Silo release. An explicit image
    # reference can still be passed.
    if [[ -z "${new_image}" ]]; then
        log_step "Resolving latest Silo release..."
        if ! new_image="$(resolve_target_image)"; then
            log_error "Update aborted. MinIO keeps running ${old_image}."
            return 1
        fi

        # Never downgrade implicitly.
        if [[ "${old_image}" == *"pgsty/silo:"* && "${new_image}" == *"pgsty/silo:"* \
              && "${new_image##*:}" < "${old_image##*:}" ]]; then
            log_success "Current image ${old_image} is newer than ${new_image}. Nothing to do."
            return 0
        fi
    fi
    if [[ ! "${new_image}" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
        die "Invalid image reference: ${new_image}"
    fi

    if image_is_unpinned "${new_image}"; then
        log_warn "Image '${new_image}' is not pinned to a version tag. Pinning a RELEASE.* tag is strongly recommended."
    fi

    if [[ "${new_image}" == "${old_image}" ]]; then
        log_success "Already running ${new_image}. Nothing to do."
        rm -f "${PROJECT_ROOT}/.update-available"
        return 0
    fi

    log_info "Release notes: https://github.com/pgsty/silo/releases/tag/${new_image##*:}"

    log_warn "Read the release notes of ${new_image} before upgrading production data."
    if prompt_yes_no "Create a backup before updating?" "Y"; then
        run_backup
    fi

    if ! confirm "Switch to ${new_image} and recreate the container?" "Y"; then
        log_info "Update cancelled."
        return 0
    fi

    log_progress "Pulling ${new_image}..."
    if ! docker pull "${new_image}"; then
        log_error "Failed to pull ${new_image}. Nothing was changed."
        return 1
    fi

    MINIO_IMAGE="${new_image}"
    set_env_key_in_file "MINIO_IMAGE" "${MINIO_IMAGE}"
    generate_compose_file
    restore_project_ownership

    log_progress "Recreating container..."
    if compose_cmd up -d --force-recreate --remove-orphans && wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        log_success "MinIO now runs ${MINIO_IMAGE}."
        rm -f "${PROJECT_ROOT}/.update-available"
        return 0
    fi

    log_error "MinIO did not become healthy on ${new_image}."
    if [[ "${old_image}" != "${new_image}" ]] && confirm "Roll back to ${old_image}?" "Y"; then
        MINIO_IMAGE="${old_image}"
        set_env_key_in_file "MINIO_IMAGE" "${MINIO_IMAGE}"
        generate_compose_file
        restore_project_ownership
        compose_cmd up -d --force-recreate --remove-orphans
        wait_for_healthy "${MINIO_CONTAINER_NAME}" || die "Rollback failed. Check: ./setup.sh logs"
        log_success "Rolled back to ${old_image}."
    fi
    return 1
}
