#!/usr/bin/env bash
# Docker network management.

readonly DEFAULT_NETWORK="minio-network"

ensure_docker_network() {
    local network="${1:-${MINIO_NETWORK:-${DEFAULT_NETWORK}}}"

    log_step "Ensuring Docker network '${network}' exists..."

    if docker network inspect "${network}" &>/dev/null; then
        log_success "Docker network '${network}' already exists."
    else
        docker network create "${network}" \
            --driver bridge \
            --label "com.minio.installer=managed"
        log_success "Created Docker network '${network}'."
    fi

    MINIO_NETWORK="${network}"
    export MINIO_NETWORK
}

remove_docker_network() {
    local network="${1:-${MINIO_NETWORK:-${DEFAULT_NETWORK}}}"

    if docker network inspect "${network}" &>/dev/null; then
        log_step "Removing Docker network '${network}'..."

        local containers
        containers=$(docker network inspect "${network}" --format='{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)

        if [[ -n "${containers// /}" ]]; then
            log_warn "Network '${network}' still has attached containers; skipping removal."
            return 0
        fi

        docker network rm "${network}" &>/dev/null || log_warn "Could not remove network '${network}'."
        log_success "Removed Docker network '${network}'."
    fi
}

show_network_endpoints() {
    local server_ip

    if [[ "${MINIO_EXPOSE_PORTS}" != "true" ]]; then
        return 0
    fi

    server_ip=$(get_primary_ip)

    echo ""
    log_success "MinIO is exposed on the host:"
    echo -e "  ${BOLD}API:${NC}     http://${server_ip}:${MINIO_API_PORT}"
    echo -e "  ${BOLD}Console:${NC} http://${server_ip}:${MINIO_CONSOLE_PORT}"
    echo ""
}
