#!/usr/bin/env bash
# Login and configuration diagnostics.

get_compose_env_value() {
    local key="$1"
    local compose_file="${PROJECT_ROOT}/docker-compose.yml"

    if [[ ! -f "${compose_file}" ]]; then
        return 1
    fi

    grep -E "^[[:space:]]*${key}:" "${compose_file}" 2>/dev/null | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d "'\""
}

cmd_diagnose() {
    local running=0
    local container_user container_pass_file
    local login_url

    if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
        die "No installation found (.env missing). Run: ./setup.sh install"
    fi

    load_env_file

    echo ""
    echo -e "${BOLD}MinIO Diagnostics${NC}"
    echo "========================================="
    echo ""

    log_step "Configuration files"
    if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
        log_success "docker-compose.yml exists"
    else
        log_error "docker-compose.yml missing — run install or reset-password"
    fi

    if [[ -f "${PROJECT_ROOT}/secrets/root_password" ]]; then
        log_success "secrets/root_password exists ($(wc -c < "${PROJECT_ROOT}/secrets/root_password") bytes)"
    else
        log_warn "secrets/root_password missing — credentials may not reach the container"
    fi

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        log_success ".env exists (username: ${MINIO_ROOT_USER})"
    fi

    echo ""
    log_step "Data volume"
    if [[ -d "${MINIO_DATA_PATH}" ]]; then
        log_success "Data path exists: ${MINIO_DATA_PATH}"
        if minio_iam_store_exists; then
            log_warn "IAM config store exists — MinIO uses stored credentials, not only .env"
            log_info "If login fails after reinstall, run: ./setup.sh reset-password"
        else
            log_success "No IAM config yet — credentials from environment will apply on first start"
        fi
    else
        log_error "Data path missing: ${MINIO_DATA_PATH}"
    fi

    echo ""
    log_step "Container"
    if docker ps --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"; then
        running=1
        log_success "Container '${MINIO_CONTAINER_NAME}' is running"

        container_user=$(docker exec "${MINIO_CONTAINER_NAME}" sh -c 'printf "%s" "$MINIO_ROOT_USER"' 2>/dev/null || echo "")
        container_pass_file=$(docker exec "${MINIO_CONTAINER_NAME}" sh -c 'printf "%s" "$MINIO_ROOT_PASSWORD_FILE"' 2>/dev/null || echo "")

        if [[ -n "${container_user}" ]]; then
            echo "  Container MINIO_ROOT_USER: ${container_user}"
            if [[ "${container_user}" != "${MINIO_ROOT_USER}" ]]; then
                log_error "Username mismatch: .env='${MINIO_ROOT_USER}' container='${container_user}'"
            fi
        fi

        if [[ -n "${container_pass_file}" ]]; then
            echo "  Container uses MINIO_ROOT_PASSWORD_FILE: ${container_pass_file}"
        elif docker exec "${MINIO_CONTAINER_NAME}" sh -c 'test -n "$MINIO_ROOT_PASSWORD"' 2>/dev/null; then
            log_warn "Container uses MINIO_ROOT_PASSWORD env (legacy); consider reset-password to migrate"
        fi
    else
        log_error "Container '${MINIO_CONTAINER_NAME}' is not running"
        log_info "Start it with: ./setup.sh start"
    fi

    echo ""
    log_step "Login URL"
    if [[ -n "${MINIO_BROWSER_REDIRECT_URL:-}" ]]; then
        login_url="${MINIO_BROWSER_REDIRECT_URL}"
        log_warn "Public Console URL is set — log in here (NOT via http://IP:${MINIO_CONSOLE_PORT}):"
        echo "  ${login_url}"
    elif [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
        login_url="http://$(get_primary_ip):${MINIO_CONSOLE_PORT}"
        echo "  Console: ${login_url}"
        echo "  API:     http://$(get_primary_ip):${MINIO_API_PORT}"
    else
        log_info "Ports not exposed to host — access Console via Docker network or reverse proxy"
    fi

    if [[ -n "${MINIO_SERVER_URL:-}" ]]; then
        echo "  Public API URL: ${MINIO_SERVER_URL}"
    fi

    echo ""
    log_step "Credential test (API via mc)"
    if [[ "${running}" -eq 1 ]]; then
        if verify_root_credentials; then
            log_success "API accepts username/password from .env"
        else
            log_error "API rejected credentials from .env"
            echo ""
            log_warn "Most common fixes:"
            echo "  1. ./setup.sh reset-password   — reset IAM and apply .env credentials"
            echo "  2. Use the Console URL shown above (public URL if configured)"
            echo "  3. Copy password exactly from install/reset output (no extra spaces)"
        fi
    else
        log_warn "Skipped — container is not running"
    fi

    echo ""
    log_step "Recent container logs (last 30 lines)"
    if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
        compose_cmd logs --tail=30 2>/dev/null || log_warn "Could not read container logs"
    else
        log_warn "No docker-compose.yml — cannot fetch logs"
    fi

    echo ""
    echo "Credentials in .env (for Console login):"
    echo "  Username: ${MINIO_ROOT_USER}"
    echo "  Password: ${MINIO_ROOT_PASSWORD}"
    echo ""
}
