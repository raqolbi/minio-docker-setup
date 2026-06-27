#!/usr/bin/env bash
# Root credential reset (IAM store on data volume).

MC_BIN="${PROJECT_ROOT}/bin/mc"

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

copy_path_elevated() {
    local src="$1"
    local dest="$2"

    if [[ "${EUID}" -eq 0 ]]; then
        cp -a "${src}" "${dest}"
    else
        sudo cp -a "${src}" "${dest}"
    fi
}

ensure_mc_client() {
    if [[ -x "${MC_BIN}" ]]; then
        return 0
    fi

    local arch os url

    os="linux"
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv6l) arch="arm" ;;
        *)
            die "Unsupported architecture for mc: $(uname -m)"
            ;;
    esac

    url="https://dl.min.io/client/mc/release/${os}-${arch}/mc"
    mkdir -p "${PROJECT_ROOT}/bin"

    log_info "Downloading mc from ${url}..."
    curl -fsSL "${url}" -o "${MC_BIN}"
    chmod +x "${MC_BIN}"
}

minio_iam_store_exists() {
    [[ -d "${MINIO_DATA_PATH}/.minio.sys/config" ]]
}

reset_minio_iam_store() {
    local config_dir="${MINIO_DATA_PATH}/.minio.sys/config"
    local backup_dir="${MINIO_DATA_PATH}/.minio.sys/config.bak-$(timestamp)"

    log_step "Resetting MinIO config store (IAM users, groups, policies)..."

    if [[ ! -d "${MINIO_DATA_PATH}/.minio.sys" ]]; then
        log_warn "MinIO system store not found; new credentials will apply on next start."
        return 0
    fi

    if [[ -d "${config_dir}" ]]; then
        log_info "Backing up current config to ${backup_dir}..."
        copy_path_elevated "${config_dir}" "${backup_dir}"
        remove_path_elevated "${config_dir}"
        log_success "Removed config store (backup: ${backup_dir})."
        return 0
    fi

    log_warn "Config store not found; continuing with credential update."
}

patch_credentials_env() {
    log_step "Updating root credentials in .env (other values unchanged)..."

    set_env_key_in_file "MINIO_ROOT_USER" "${MINIO_ROOT_USER}"
    set_env_key_in_file "MINIO_ROOT_PASSWORD" "${MINIO_ROOT_PASSWORD}"

    log_success "Root credentials updated in .env"

    log_step "Updating credentials in docker-compose.yml and secrets file..."
    generate_compose_file
}

mc_verify_with_shared_config() {
    local endpoint="$1"
    local mc_config err_log

    mc_config=$(mktemp -d)
    err_log=$(mktemp)

    if docker run --rm --network "${MINIO_NETWORK}" \
        -v "${mc_config}:/root/.mc" \
        minio/mc:latest alias set verifyminio "${endpoint}" \
        "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 2>"${err_log}" && \
       docker run --rm --network "${MINIO_NETWORK}" \
        -v "${mc_config}:/root/.mc" \
        minio/mc:latest ls verifyminio &>>"${err_log}"; then
        rm -rf "${mc_config}" "${err_log}"
        return 0
    fi

    if [[ -s "${err_log}" ]]; then
        log_warn "Verification detail: $(tail -n1 "${err_log}")"
    fi

    rm -rf "${mc_config}" "${err_log}"
    return 1
}

mc_verify_credentials_once() {
    local endpoint

    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        ensure_mc_client
        endpoint="http://127.0.0.1:${MINIO_API_PORT}"

        if "${MC_BIN}" alias set verifyminio "${endpoint}" \
            "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null && \
           "${MC_BIN}" ls verifyminio &>/dev/null; then
            "${MC_BIN}" alias rm verifyminio &>/dev/null || true
            return 0
        fi

        return 1
    fi

    endpoint="http://${MINIO_CONTAINER_NAME}:9000"
    mc_verify_with_shared_config "${endpoint}"
}

verify_root_credentials() {
    local attempt=0
    local max_attempts=6

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
