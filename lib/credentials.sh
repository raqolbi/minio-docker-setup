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
    local format_file="${iam_dir}/format.json"

    log_step "Resetting MinIO IAM credential store..."

    if [[ ! -d "${MINIO_DATA_PATH}/.minio.sys" ]]; then
        log_warn "MinIO system store not found; new credentials will apply on next start."
        return 0
    fi

    if [[ -f "${format_file}" ]]; then
        remove_path_elevated "${format_file}"
        log_success "Removed IAM format store."
        return 0
    fi

    if [[ -d "${iam_dir}" ]]; then
        remove_path_elevated "${iam_dir}"
        log_success "Removed IAM configuration directory."
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
