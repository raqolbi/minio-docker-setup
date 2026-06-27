#!/usr/bin/env bash
# Docker installation and container management.

install_docker() {
    log_step "Installing Docker Engine..."

    require_root_for_docker_install

    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
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
                    log_success "MinIO API is reachable (Docker health probe unavailable in minimal image)."
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
    return 1
}

check_api_internal() {
    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        curl -fsS --max-time 5 "http://127.0.0.1:${MINIO_API_PORT}/minio/health/live" &>/dev/null
        return $?
    fi

    docker run --rm --network "${MINIO_NETWORK}" curlimages/curl:latest \
        -fsS --max-time 5 "http://${MINIO_CONTAINER_NAME}:9000/minio/health/live" &>/dev/null
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
        code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:${MINIO_CONSOLE_PORT}/" 2>/dev/null || echo "000")

        if [[ "${code}" =~ ^[23] ]]; then
            log_success "MinIO Console is reachable (HTTP ${code})."
            return 0
        fi

        log_error "MinIO Console is not reachable (HTTP ${code})."
        return 1
    fi

    if docker run --rm --network "${MINIO_NETWORK}" curlimages/curl:latest \
        -fsS --max-time 5 -o /dev/null "http://${MINIO_CONTAINER_NAME}:9001/" &>/dev/null; then
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
    load_env_file
    compose_cmd logs -f --tail=100
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

        if [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
            echo "API:     http://$(get_primary_ip):${MINIO_API_PORT}"
            echo "Console: http://$(get_primary_ip):${MINIO_CONSOLE_PORT}"
        else
            echo "API/Console: internal Docker network only"
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

cmd_update() {
    load_env_file
    log_progress "Pulling latest MinIO image..."
    compose_cmd pull
    log_progress "Recreating containers..."
    compose_cmd up -d
    wait_for_healthy "${MINIO_CONTAINER_NAME}"
    log_success "MinIO updated to latest image."
}
