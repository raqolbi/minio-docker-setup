#!/usr/bin/env bash
# Root credential reset (IAM store on data volume).

remove_path_elevated() {
    local path="$1"

    if [[ ! -e "${path}" ]]; then
        return 0
    fi

    if [[ "${EUID}" -eq 0 ]]; then
        rm -rf "${path}"
    else
        sudo rm -rf "${path}"
    fi
}

reset_minio_iam_store() {
    local iam_dir="${MINIO_DATA_PATH}/.minio.sys/config/iam"

    log_step "Resetting MinIO IAM store (users, groups, policies)..."

    if [[ ! -d "${MINIO_DATA_PATH}/.minio.sys" ]]; then
        log_warn "MinIO system store not found; new credentials will apply on next start."
        return 0
    fi

    if [[ -d "${iam_dir}" ]]; then
        remove_path_elevated "${iam_dir}"
        log_success "Removed IAM store (users, groups, service accounts, and policies)."
        return 0
    fi

    log_warn "IAM store not found; continuing with credential update."
}

patch_credentials_env() {
    log_step "Updating root credentials in .env (other values unchanged)..."

    set_env_key_in_file "MINIO_ROOT_USER" "${MINIO_ROOT_USER}"
    set_env_key_in_file "MINIO_ROOT_PASSWORD" "${MINIO_ROOT_PASSWORD}"

    log_success "Root credentials updated in .env"
}

verify_root_credentials() {
    local attempt=0
    local max_attempts=12

    log_step "Verifying new root credentials against MinIO API..."

    while [[ "${attempt}" -lt "${max_attempts}" ]]; do
        if mc_verify_credentials_once; then
            log_success "Root credentials verified successfully."
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "${attempt}" -lt "${max_attempts}" ]]; then
            log_info "Waiting for MinIO to accept new credentials (${attempt}/${max_attempts})..."
            sleep 5
        fi
    done

    log_error "Credential verification failed."
    return 1
}

mc_verify_credentials_once() {
    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        docker run --rm --network host minio/mc:latest \
            alias set verifyminio "http://127.0.0.1:${MINIO_API_PORT}" \
            "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null && \
        docker run --rm --network host minio/mc:latest \
            admin info verifyminio &>/dev/null
        return $?
    fi

    docker run --rm --network "${MINIO_NETWORK}" minio/mc:latest \
        alias set verifyminio "http://${MINIO_CONTAINER_NAME}:9000" \
        "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null && \
    docker run --rm --network "${MINIO_NETWORK}" minio/mc:latest \
        admin info verifyminio &>/dev/null
}
