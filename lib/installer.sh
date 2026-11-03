#!/usr/bin/env bash
# Main installation, backup, restore, uninstall, and access management.

run_installation() {
    local server_ip api_endpoint console_endpoint

    show_banner

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        log_warn "An installation already exists in ${PROJECT_ROOT} (.env found)."
        log_warn "Reinstalling overwrites its configuration and root credentials."
        log_info "To change only the password use: ./setup.sh reset-password; to upgrade: ./setup.sh update"
        if ! confirm "Reinstall anyway?" "N"; then
            log_info "Install cancelled. Nothing was changed."
            return 0
        fi
    fi

    collect_install_config

    log_progress "Running pre-install validation..."
    ensure_docker_available
    run_pre_install_validation
    assert_data_path_not_in_use "${MINIO_DATA_PATH}"

    log_step "Resolving latest Silo release..."
    MINIO_IMAGE="$(resolve_target_image)" || die "Installation aborted: cannot resolve the Silo image. Nothing was changed."
    export MINIO_IMAGE
    log_success "Using image ${MINIO_IMAGE}"

    # All confirmations happen BEFORE any file is written, so cancelling
    # leaves an existing installation untouched.
    if minio_iam_store_exists; then
        echo ""
        log_warn "Existing MinIO data found at ${MINIO_DATA_PATH}"
        log_info "Buckets, objects, IAM users, policies and access keys will be kept."
        log_info "The root username/password chosen now will apply (read from the environment on start)."
        if ! confirm "Continue with the existing data?" "Y"; then
            die "Install cancelled. Choose an empty storage path for a fresh installation."
        fi
    fi

    local replace_container="false"
    if docker ps -a --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"; then
        log_warn "A container named '${MINIO_CONTAINER_NAME}' already exists."
        if ! confirm "Remove it and create a new one? (data on disk is not touched)" "N"; then
            die "Install cancelled. Choose another container name or uninstall first."
        fi
        replace_container="true"
    fi

    log_progress "Pulling image ${MINIO_IMAGE}..."
    docker pull "${MINIO_IMAGE}" || die "Failed to pull ${MINIO_IMAGE}. Nothing was changed."

    log_progress "Generating configuration files..."
    generate_config_files

    if [[ "${replace_container}" == "true" ]]; then
        docker rm -f "${MINIO_CONTAINER_NAME}" >/dev/null
    fi

    ensure_docker_network "${MINIO_NETWORK:-minio-network}"

    log_progress "Starting MinIO container..."
    compose_cmd up -d

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO failed to start. Check logs with: ./setup.sh logs"
    fi
    restore_project_ownership

    log_progress "Running post-start health checks..."
    if ! run_health_checks; then
        log_warn "Some health checks failed. Review logs with: ./setup.sh logs"
    fi

    log_progress "Verifying root credentials..."
    if ! verify_root_credentials; then
        if minio_iam_store_exists; then
            log_warn "Existing data may come from a very old MinIO version whose config was"
            log_warn "encrypted with the previous root credentials."
            log_warn "Run ./setup.sh reset-password (it offers a last-resort IAM reset)."
        fi
        die "Installation finished but login credentials could not be verified. Check: ./setup.sh diagnose"
    fi

    if [[ -n "${MINIO_BUCKETS:-}" || "${MINIO_SETUP_APP_USER:-false}" == "true" ]]; then
        log_progress "Configuring buckets, IAM policy, and application user..."
        persist_access_config
        apply_buckets_and_access || log_warn "Bucket and access setup encountered issues."
    fi

    server_ip=$(display_host)

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

    local new_user="${MINIO_ROOT_USER}" new_password="${MINIO_ROOT_PASSWORD}"

    # Root credentials are read from the environment on every start, and IAM
    # data is not encrypted with them, so a recreate is all that is needed.
    patch_credentials_env
    load_env_file
    MINIO_ROOT_USER="${new_user}"
    MINIO_ROOT_PASSWORD="${new_password}"

    log_progress "Recreating MinIO with new credentials..."
    compose_recreate

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO failed to start after credential reset. Check logs with: ./setup.sh logs"
    fi

    if ! verify_root_credentials; then
        log_error "New credentials could not be verified via API."

        if ! minio_iam_store_exists; then
            die "Credential reset incomplete. Check: ./setup.sh diagnose"
        fi

        echo ""
        log_warn "LAST RESORT: data written by very old MinIO versions encrypts its config with"
        log_warn "the previous root credentials. Resetting the IAM store fixes that, but DELETES"
        log_warn "all IAM users, groups, policies and access keys (a backup copy is kept)."
        if ! confirm "Reset the IAM store now?" "N"; then
            die "Credential reset incomplete. Check: ./setup.sh diagnose"
        fi

        compose_cmd down --remove-orphans
        reset_minio_iam_store
        compose_cmd up -d
        wait_for_healthy "${MINIO_CONTAINER_NAME}" || die "MinIO failed to start. Check: ./setup.sh logs"
        verify_root_credentials || die "Credential reset incomplete. Check: ./setup.sh diagnose"

        if [[ -n "${MINIO_BUCKETS:-}" || "${MINIO_SETUP_APP_USER:-false}" == "true" ]]; then
            log_progress "Re-creating application user and bucket policies..."
            apply_buckets_and_access || log_warn "Re-apply with: ./setup.sh manage-access full"
        fi
    fi

    if ! run_health_checks; then
        log_warn "Some health checks failed. Review logs with: ./setup.sh logs"
    fi

    show_reset_credentials_complete
}

# Reject archives with absolute paths or '..' components.
archive_paths_safe() {
    local list_file="$1"

    ! grep -qE '(^/|(^|/)\.\.(/|$))' "${list_file}"
}

run_as_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_backup() {
    local backup_dir backup_name archive_path temp_dir
    local stopped=0 failed=0

    load_env_file
    acquire_operation_lock

    backup_dir="${PROJECT_ROOT}/backups"
    backup_name="backup-$(timestamp)"
    temp_dir="${backup_dir}/${backup_name}"
    archive_path="${backup_dir}/${backup_name}.tar.gz"

    mkdir -p "${backup_dir}"
    chmod 700 "${backup_dir}"

    log_progress "Creating backup: ${archive_path}"

    mkdir -p "${temp_dir}/config"
    cp "${PROJECT_ROOT}/docker-compose.yml" "${temp_dir}/config/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/.env" "${temp_dir}/config/"

    if [[ -d "${PROJECT_ROOT}/secrets" ]]; then
        cp -a "${PROJECT_ROOT}/secrets" "${temp_dir}/secrets"
    fi

    if [[ -d "${MINIO_DATA_PATH}" ]]; then
        local data_kb free_kb
        data_kb=$(run_as_root du -sk "${MINIO_DATA_PATH}" 2>/dev/null | awk '{print $1}')
        free_kb=$(df -Pk "${backup_dir}" 2>/dev/null | awk 'NR==2 {print $4}')
        # Uncompressed data.tar + compressed archive coexist briefly.
        if [[ -n "${data_kb}" && -n "${free_kb}" && $((data_kb * 2)) -gt "${free_kb}" ]]; then
            rm -rf "${temp_dir}"
            die "Not enough free space in ${backup_dir}: need ~$((data_kb * 2 / 1024)) MB, have $((free_kb / 1024)) MB."
        fi

        if container_is_running; then
            log_warn "Copying data files while MinIO is writing can produce an inconsistent backup."
            if prompt_yes_no "Stop MinIO during the backup (short downtime)?" "Y"; then
                compose_cmd stop
                stopped=1
            fi
        fi

        log_step "Archiving MinIO data from ${MINIO_DATA_PATH}..."
        run_as_root tar -C "$(dirname "${MINIO_DATA_PATH}")" -cf "${temp_dir}/data.tar" \
            "$(basename "${MINIO_DATA_PATH}")" || failed=1

        if [[ "${stopped}" -eq 1 ]]; then
            log_step "Starting MinIO again..."
            compose_cmd start || log_error "Failed to restart MinIO. Run: ./setup.sh start"
        fi
    else
        log_warn "Data path not found; backing up config only."
    fi

    if [[ "${failed}" -ne 0 ]]; then
        run_as_root rm -rf "${temp_dir}"
        die "Data archive failed; backup aborted."
    fi

    run_as_root chown -R "$(id -u):$(id -g)" "${temp_dir}" 2>/dev/null || true
    ( umask 077; tar -czf "${archive_path}" -C "${backup_dir}" "${backup_name}" ) || die "Failed to write ${archive_path}"
    chmod 600 "${archive_path}"
    rm -rf "${temp_dir}"
    restore_project_ownership

    log_success "Backup created: ${archive_path}"
    log_warn "The archive contains credentials (secrets/). Store it securely, preferably off this server."
}

# read_env_value FILE KEY — value of KEY from a dotenv file (unquoted).
read_env_value() {
    local file="$1" key="$2" line

    [[ -f "${file}" ]] || return 0
    line=$(grep -E "^${key}=" "${file}" | tail -n1) || return 0
    parse_dotenv_value "${line#*=}"
}

run_restore() {
    local archive_path="${1:-}"
    local restore_dir extracted list_file data_path data_parent staging restored_dir old_copy=""
    local fresh_restore="false" need_kb free_kb

    if [[ -z "${archive_path}" ]]; then
        read -r -p "Enter path to backup archive (.tar.gz): " archive_path
    fi

    [[ -f "${archive_path}" ]] || die "Backup archive not found: ${archive_path}"
    archive_path="$(cd "$(dirname "${archive_path}")" && pwd)/$(basename "${archive_path}")"

    # Restoring onto a fresh server (no .env yet) is supported: configuration
    # comes from the archive.
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        load_env_file
    else
        fresh_restore="true"
        log_info "No existing installation found; configuration will come from the archive."
        ensure_docker_available
        validate_docker_compose
    fi
    acquire_operation_lock

    log_step "Validating backup archive..."
    list_file=$(mktemp)
    if ! tar -tzf "${archive_path}" > "${list_file}" 2>/dev/null; then
        rm -f "${list_file}"
        die "Archive is corrupt or not a .tar.gz: ${archive_path}"
    fi
    if ! archive_paths_safe "${list_file}"; then
        rm -f "${list_file}"
        die "Archive contains unsafe paths; refusing to restore."
    fi
    rm -f "${list_file}"

    log_warn "This will stop MinIO and replace current configuration and data."
    log_info "The current data directory is kept as a rollback copy (not deleted)."
    if ! confirm "Proceed with restore?" "N"; then
        log_info "Restore cancelled."
        return 0
    fi

    restore_dir="${PROJECT_ROOT}/.restore-$(timestamp)"
    ( umask 077; mkdir -p "${restore_dir}" )
    # Clean up the extracted copy (it contains credentials) on any exit path.
    # shellcheck disable=SC2064  # expand now: restore_dir is local
    trap "rm -rf $(printf '%q' "${restore_dir}")" EXIT

    log_step "Extracting backup archive..."
    tar -xzf "${archive_path}" -C "${restore_dir}" || die "Failed to extract ${archive_path}"

    extracted=$(find "${restore_dir}" -mindepth 1 -maxdepth 1 -type d | head -n1)
    [[ -n "${extracted}" ]] || die "Invalid backup archive structure."

    if [[ "${fresh_restore}" == "true" && ! -f "${extracted}/config/.env" ]]; then
        die "Archive has no config/.env; cannot restore onto a fresh server."
    fi

    # Target data path: the one recorded in the backup, else the current one.
    data_path="$(read_env_value "${extracted}/config/.env" MINIO_DATA_PATH)"
    data_path="${data_path:-${MINIO_DATA_PATH:-}}"

    # ---- Phase 1: prepare data in a staging dir (MinIO keeps running) ----
    if [[ -f "${extracted}/data.tar" ]]; then
        [[ -n "${data_path}" ]] || die "Cannot determine the data path for the restore."
        assert_safe_data_path "${data_path}"

        list_file=$(mktemp)
        if ! tar -tf "${extracted}/data.tar" > "${list_file}" 2>/dev/null || ! archive_paths_safe "${list_file}"; then
            rm -f "${list_file}"
            die "data.tar in the archive is corrupt or contains unsafe paths."
        fi
        rm -f "${list_file}"

        data_parent=$(dirname "${data_path}")
        run_as_root mkdir -p "${data_parent}"

        need_kb=$(( $(stat -c %s "${extracted}/data.tar") / 1024 ))
        free_kb=$(df -Pk "${data_parent}" 2>/dev/null | awk 'NR==2 {print $4}')
        if [[ -n "${free_kb}" && "${need_kb}" -gt "${free_kb}" ]]; then
            die "Not enough free space in ${data_parent}: need ~$((need_kb / 1024)) MB, have $((free_kb / 1024)) MB. Nothing was changed."
        fi

        staging="${data_path}.restore-staging-$(timestamp)"
        log_step "Extracting data to staging directory ${staging}..."
        run_as_root install -d -m 700 "${staging}"
        if ! run_as_root tar -xf "${extracted}/data.tar" -C "${staging}"; then
            run_as_root rm -rf "${staging}"
            die "Data extraction failed. Nothing was changed."
        fi

        restored_dir=$(run_as_root find "${staging}" -mindepth 1 -maxdepth 1 -type d | head -n1)
        if [[ -z "${restored_dir}" ]]; then
            run_as_root rm -rf "${staging}"
            die "No data directory found in the backup. Nothing was changed."
        fi
    fi

    # ---- Phase 2: stop, swap data, apply configuration ----
    if [[ "${fresh_restore}" == "false" && -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
        log_step "Stopping MinIO..."
        compose_cmd stop 2>/dev/null || true
    fi

    if [[ -n "${restored_dir:-}" ]]; then
        if [[ -e "${data_path}" ]]; then
            old_copy="${data_path}.pre-restore-$(timestamp)"
            log_step "Keeping current data as ${old_copy}..."
            run_as_root mv "${data_path}" "${old_copy}"
        fi
        run_as_root mv "${restored_dir}" "${data_path}"
        run_as_root rmdir "${staging}" 2>/dev/null || true
    fi

    if [[ -d "${extracted}/secrets" ]]; then
        mkdir -p "${PROJECT_ROOT}/secrets"
        chmod 700 "${PROJECT_ROOT}/secrets"
        cp -a "${extracted}/secrets/." "${PROJECT_ROOT}/secrets/"
        chmod 600 "${PROJECT_ROOT}"/secrets/* 2>/dev/null || true
    fi

    if [[ -f "${extracted}/config/.env" ]]; then
        cp "${extracted}/config/.env" "${PROJECT_ROOT}/.env"
        chmod 600 "${PROJECT_ROOT}/.env"
        load_env_file
        generate_compose_file
    elif [[ -f "${extracted}/config/docker-compose.yml" ]]; then
        cp "${extracted}/config/docker-compose.yml" "${PROJECT_ROOT}/docker-compose.yml"
    fi

    rm -rf "${restore_dir}"
    trap - EXIT

    restore_project_ownership
    ensure_docker_network "${MINIO_NETWORK:-minio-network}"

    log_step "Starting MinIO..."
    compose_cmd up -d
    wait_for_healthy "${MINIO_CONTAINER_NAME}" || die "MinIO did not become healthy after restore. Check: ./setup.sh logs"
    run_health_checks || log_warn "Some health checks failed. Review: ./setup.sh diagnose"

    log_success "Restore completed successfully."
    if [[ -n "${old_copy}" ]]; then
        log_warn "Previous data kept at ${old_copy} — delete it once the restore is verified."
    fi
    if [[ -n "${AUTO_UPDATE_MODE:-}" && ! -f "/etc/systemd/system/$(auto_update_unit_name).timer" ]]; then
        log_info "The backup had auto-update enabled; re-enable it with: ./setup.sh auto-update enable"
    fi
}

run_uninstall() {
    local remove_data="${1:-false}"
    local env_file="${PROJECT_ROOT}/.env"

    if [[ -f "${env_file}" ]]; then
        load_env_file
    fi

    log_progress "Uninstalling MinIO..."

    if [[ -n "${MINIO_CONTAINER_NAME:-}" && -f "/etc/systemd/system/$(auto_update_unit_name).timer" ]]; then
        log_step "Removing auto-update timer..."
        run_as_root systemctl disable --now "$(auto_update_unit_name).timer" 2>/dev/null || true
        run_as_root rm -f "/etc/systemd/system/$(auto_update_unit_name).timer" \
            "/etc/systemd/system/$(auto_update_unit_name).service"
        run_as_root systemctl daemon-reload || true
    fi

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
    rm -f "${PROJECT_ROOT}/.update-available"

    if [[ "${remove_data}" == "true" && -n "${MINIO_DATA_PATH:-}" && -d "${MINIO_DATA_PATH}" ]]; then
        assert_safe_data_path "${MINIO_DATA_PATH}"
        log_warn "Removing data directory: ${MINIO_DATA_PATH}"
        run_as_root rm -rf "${MINIO_DATA_PATH}"
    fi

    log_success "MinIO uninstalled."
    log_info "Templates and scripts remain in ${PROJECT_ROOT}"
    if compgen -G "${PROJECT_ROOT}/backups/*.tar.gz" >/dev/null; then
        log_warn "Backups in ${PROJECT_ROOT}/backups contain credentials and data; delete them if no longer needed."
    fi
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
