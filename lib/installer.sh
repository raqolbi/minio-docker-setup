#!/usr/bin/env bash
# Main installation, backup, restore, uninstall, and access management.

run_installation() {
    local server_ip api_endpoint console_endpoint

    show_banner
    collect_install_config

    log_progress "Running pre-install validation..."
    ensure_docker_available
    run_pre_install_validation

    log_progress "Generating configuration files..."
    generate_config_files

    if minio_iam_store_exists; then
        echo ""
        log_warn "Existing MinIO data found at ${MINIO_DATA_PATH}"
        log_warn "Stored IAM credentials override .env — new password will NOT work until IAM is reset."
        if ! confirm "Reset IAM config and apply new credentials?" "Y"; then
            die "Install cancelled. Use an empty data path, or run ./setup.sh reset-password on an existing install."
        fi
        log_progress "Stopping any existing container..."
        compose_cmd down --remove-orphans 2>/dev/null || true
        reset_minio_iam_store
    fi

    ensure_docker_network "${MINIO_NETWORK:-minio-network}"

    log_progress "Starting MinIO container..."
    compose_cmd up -d

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO failed to start. Check logs with: ./setup.sh logs"
    fi

    log_progress "Running post-start health checks..."
    if ! run_health_checks; then
        log_warn "Some health checks failed. Review logs with: ./setup.sh logs"
    fi

    log_progress "Verifying root credentials..."
    if ! verify_root_credentials; then
        die "Installation finished but login credentials could not be verified. Check: ./setup.sh logs"
    fi

    if [[ -n "${MINIO_BUCKETS:-}" || "${MINIO_SETUP_APP_USER:-false}" == "true" ]]; then
        log_progress "Configuring buckets, IAM policy, and application user..."
        persist_access_config
        apply_buckets_and_access || log_warn "Bucket and access setup encountered issues."
    fi

    server_ip=$(get_primary_ip)

    if [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
        api_endpoint="http://${server_ip}:${MINIO_API_PORT}"
        console_endpoint="http://${server_ip}:${MINIO_CONSOLE_PORT}"
        show_network_endpoints
    else
        api_endpoint="Internal (Docker network: ${MINIO_NETWORK})"
        console_endpoint="Internal (Docker network: ${MINIO_NETWORK})"
    fi

    show_install_complete "${server_ip}" "${api_endpoint}" "${console_endpoint}"
    show_access_summary "${server_ip}" "${api_endpoint}" "${console_endpoint}"
}

run_update_public_urls() {
    load_env_file

    show_update_urls_banner
    collect_public_url_config "true"

    log_info "Root password and other settings will not be modified."
    update_public_url_config

    log_progress "Applying configuration (recreating container)..."
    compose_recreate

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO failed to restart after URL update. Check logs with: ./setup.sh logs"
    fi

    echo ""
    log_success "Public URLs updated successfully."
    echo -e "  ${BOLD}MINIO_SERVER_URL:${NC}           ${MINIO_SERVER_URL:-(not set)}"
    echo -e "  ${BOLD}MINIO_BROWSER_REDIRECT_URL:${NC} ${MINIO_BROWSER_REDIRECT_URL:-(not set)}"
    echo ""
    log_info "Root password is unchanged — use the password from your original installation."

    if [[ -n "${MINIO_BROWSER_REDIRECT_URL}" ]]; then
        echo ""
        log_warn "Open Console using the public URL above, not http://IP:${MINIO_CONSOLE_PORT}"
        log_warn "Login via direct IP/port often fails when MINIO_BROWSER_REDIRECT_URL is set."
    fi
    echo ""
}

run_reset_credentials() {
    load_env_file

    show_reset_credentials_banner
    collect_reset_credentials

    log_progress "Stopping and removing MinIO container..."
    compose_cmd down --remove-orphans

    reset_minio_iam_store
    patch_credentials_env
    load_env_file

    log_progress "Starting MinIO with new credentials..."
    compose_recreate

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO failed to start after credential reset. Check logs with: ./setup.sh logs"
    fi

    if ! verify_root_credentials; then
        log_error "New credentials could not be verified via API."
        log_warn "Check: ./setup.sh logs"
        log_warn "Ensure MINIO_DATA_PATH is correct: ${MINIO_DATA_PATH}"
        die "Credential reset incomplete."
    fi

    if ! run_health_checks; then
        log_warn "Some health checks failed. Review logs with: ./setup.sh logs"
    fi

    show_reset_credentials_complete
}

run_backup() {
    local backup_dir backup_name archive_path temp_dir

    load_env_file

    backup_dir="${PROJECT_ROOT}/backups"
    backup_name="backup-$(timestamp)"
    temp_dir="${backup_dir}/${backup_name}"
    archive_path="${backup_dir}/${backup_name}.tar.gz"

    mkdir -p "${backup_dir}"

    log_progress "Creating backup: ${archive_path}"

    mkdir -p "${temp_dir}/config"
    cp "${PROJECT_ROOT}/docker-compose.yml" "${temp_dir}/config/"
    cp "${PROJECT_ROOT}/.env" "${temp_dir}/config/"

    if [[ -f "${PROJECT_ROOT}/secrets/root_password" ]]; then
        mkdir -p "${temp_dir}/secrets"
        cp "${PROJECT_ROOT}/secrets/root_password" "${temp_dir}/secrets/"
        chmod 600 "${temp_dir}/secrets/root_password"
    fi

    if [[ -f "${PROJECT_ROOT}/secrets/app_password" ]]; then
        mkdir -p "${temp_dir}/secrets"
        cp "${PROJECT_ROOT}/secrets/app_password" "${temp_dir}/secrets/"
        chmod 600 "${temp_dir}/secrets/app_password"
    fi

    log_step "Archiving MinIO data from ${MINIO_DATA_PATH}..."
    if [[ -d "${MINIO_DATA_PATH}" ]]; then
        if [[ "${EUID}" -eq 0 ]]; then
            tar -C "$(dirname "${MINIO_DATA_PATH}")" -cf "${temp_dir}/data.tar" "$(basename "${MINIO_DATA_PATH}")"
        else
            sudo tar -C "$(dirname "${MINIO_DATA_PATH}")" -cf "${temp_dir}/data.tar" "$(basename "${MINIO_DATA_PATH}")"
        fi
    else
        log_warn "Data path not found; backing up config only."
    fi

    tar -czf "${archive_path}" -C "${backup_dir}" "${backup_name}"
    rm -rf "${temp_dir}"

    log_success "Backup created: ${archive_path}"
}

run_restore() {
    local archive_path="$1"
    local restore_dir data_parent

    if [[ -z "${archive_path}" ]]; then
        read -r -p "Enter path to backup archive (.tar.gz): " archive_path
    fi

    if [[ ! -f "${archive_path}" ]]; then
        die "Backup archive not found: ${archive_path}"
    fi

    load_env_file

    log_warn "This will stop MinIO and overwrite current configuration and data."
    if ! confirm "Proceed with restore?" "N"; then
        log_info "Restore cancelled."
        return 0
    fi

    restore_dir="${PROJECT_ROOT}/.restore-$(timestamp)"
    mkdir -p "${restore_dir}"

    log_step "Extracting backup archive..."
    tar -xzf "${archive_path}" -C "${restore_dir}"

    local extracted
    extracted=$(find "${restore_dir}" -mindepth 1 -maxdepth 1 -type d | head -n1)

    if [[ -z "${extracted}" ]]; then
        die "Invalid backup archive structure."
    fi

    log_step "Stopping MinIO..."
    compose_cmd stop 2>/dev/null || true

    if [[ -f "${extracted}/config/.env" ]]; then
        cp "${extracted}/config/.env" "${PROJECT_ROOT}/.env"
        chmod 600 "${PROJECT_ROOT}/.env"
        load_env_file
        generate_compose_file
        if [[ -f "${extracted}/secrets/root_password" ]]; then
            mkdir -p "${PROJECT_ROOT}/secrets"
            cp "${extracted}/secrets/root_password" "${PROJECT_ROOT}/secrets/root_password"
            chmod 600 "${PROJECT_ROOT}/secrets/root_password"
            chmod 700 "${PROJECT_ROOT}/secrets"
        fi
        if [[ -f "${extracted}/secrets/app_password" ]]; then
            mkdir -p "${PROJECT_ROOT}/secrets"
            cp "${extracted}/secrets/app_password" "${PROJECT_ROOT}/secrets/app_password"
            chmod 600 "${PROJECT_ROOT}/secrets/app_password"
            chmod 700 "${PROJECT_ROOT}/secrets"
        fi
    elif [[ -f "${extracted}/config/docker-compose.yml" ]]; then
        cp "${extracted}/config/docker-compose.yml" "${PROJECT_ROOT}/docker-compose.yml"
        if [[ -f "${extracted}/secrets/root_password" ]]; then
            mkdir -p "${PROJECT_ROOT}/secrets"
            cp "${extracted}/secrets/root_password" "${PROJECT_ROOT}/secrets/root_password"
            chmod 600 "${PROJECT_ROOT}/secrets/root_password"
            chmod 700 "${PROJECT_ROOT}/secrets"
        fi
        if [[ -f "${extracted}/secrets/app_password" ]]; then
            mkdir -p "${PROJECT_ROOT}/secrets"
            cp "${extracted}/secrets/app_password" "${PROJECT_ROOT}/secrets/app_password"
            chmod 600 "${PROJECT_ROOT}/secrets/app_password"
            chmod 700 "${PROJECT_ROOT}/secrets"
        fi
    fi

    if [[ -f "${extracted}/data.tar" ]]; then
        data_parent=$(dirname "${MINIO_DATA_PATH}")
        log_step "Restoring data to ${MINIO_DATA_PATH}..."

        if [[ "${EUID}" -eq 0 ]]; then
            rm -rf "${MINIO_DATA_PATH}"
            mkdir -p "${data_parent}"
            tar -xf "${extracted}/data.tar" -C "${data_parent}"
        else
            sudo rm -rf "${MINIO_DATA_PATH}"
            sudo mkdir -p "${data_parent}"
            sudo tar -xf "${extracted}/data.tar" -C "${data_parent}"
            sudo chown -R "${USER}:${USER}" "${MINIO_DATA_PATH}" 2>/dev/null || true
        fi
    fi

    rm -rf "${restore_dir}"

    log_step "Starting MinIO..."
    compose_cmd up -d
    wait_for_healthy "${MINIO_CONTAINER_NAME}"
    run_health_checks

    log_success "Restore completed successfully."
}

run_uninstall() {
    local remove_data="${1:-false}"
    local env_file="${PROJECT_ROOT}/.env"

    if [[ -f "${env_file}" ]]; then
        load_env_file
    fi

    log_progress "Uninstalling MinIO..."

    if [[ -f "${PROJECT_ROOT}/docker-compose.yml" ]] && [[ -f "${env_file}" ]]; then
        log_step "Stopping and removing containers..."
        compose_cmd down --remove-orphans 2>/dev/null || docker compose -f "${PROJECT_ROOT}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
    elif [[ -n "${MINIO_CONTAINER_NAME:-}" ]]; then
        docker rm -f "${MINIO_CONTAINER_NAME}" 2>/dev/null || true
    fi

    remove_docker_network "${MINIO_NETWORK:-minio-network}"

    log_step "Removing generated configuration..."
    rm -f "${PROJECT_ROOT}/docker-compose.yml" "${PROJECT_ROOT}/.env"
    rm -rf "${PROJECT_ROOT}/secrets"

    if [[ "${remove_data}" == "true" && -n "${MINIO_DATA_PATH:-}" && -d "${MINIO_DATA_PATH}" ]]; then
        log_warn "Removing data directory: ${MINIO_DATA_PATH}"
        if [[ "${EUID}" -eq 0 ]]; then
            rm -rf "${MINIO_DATA_PATH}"
        else
            sudo rm -rf "${MINIO_DATA_PATH}"
        fi
    fi

    log_success "MinIO uninstalled."
    log_info "Templates and scripts remain in ${PROJECT_ROOT}"
}

prompt_uninstall() {
    local remove_data="false"

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        load_env_file
    fi

    echo ""
    echo -e "${YELLOW}${BOLD}MinIO Uninstaller${NC}"
    echo ""

    if ! confirm "Remove MinIO containers and configuration?" "N"; then
        log_info "Uninstall cancelled."
        return 0
    fi

    if prompt_yes_no "Also delete data directory (${MINIO_DATA_PATH:-/opt/minio/data})?" "N"; then
        remove_data="true"
    fi

    run_uninstall "${remove_data}"
}
