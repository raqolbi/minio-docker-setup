#!/usr/bin/env bash
# Root credential management and verification.
#
# All mc/mcli commands run INSIDE the MinIO container (both pgsty/silo and
# minio/minio images bundle the client). Credentials are passed over stdin and
# exposed to mc only via an MC_HOST_* variable inside the container, so they
# never appear in host process arguments or in a persistent mc config file.

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

container_is_running() {
    docker ps --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"
}

# container_mc USER PASSWORD INPUT_FILE -- mc-args...
# INPUT_FILE (may be empty) is streamed to mc's stdin after the credentials;
# reference it in mc-args as /dev/stdin.
container_mc() {
    local user="$1"
    local pass="$2"
    local input_file="$3"
    shift 3

    local creds alias_var
    creds="$(url_encode "${user}"):$(url_encode "${pass}")"
    alias_var="MC_HOST_${MC_ALIAS}"

    {
        printf '%s\n' "${creds}"
        if [[ -n "${input_file}" ]]; then
            cat "${input_file}"
        fi
    } | docker exec -i "${MINIO_CONTAINER_NAME}" sh -c '
        IFS= read -r __creds || exit 97
        M=$(command -v mcli 2>/dev/null || command -v mc 2>/dev/null) || {
            echo "mc/mcli client not found inside the MinIO image" >&2
            exit 98
        }
        export "'"${alias_var}"'=http://${__creds}@127.0.0.1:9000"
        unset __creds
        exec "$M" "$@"' mc "$@"
}

minio_iam_store_exists() {
    [[ -d "${MINIO_DATA_PATH}/.minio.sys/config" ]]
}

# Last-resort recovery ONLY. Modern MinIO/Silo read root credentials from the
# environment on every start and store IAM data unencrypted (or KMS-encrypted),
# so changing the root password does NOT require this. It is only needed for
# very old data whose config was encrypted with the previous root credentials.
# WARNING: removes all IAM users, groups, policies and access keys.
reset_minio_iam_store() {
    local config_dir="${MINIO_DATA_PATH}/.minio.sys/config"
    local backup_dir
    backup_dir="${MINIO_DATA_PATH}/.minio.sys/config.bak-$(timestamp)"

    log_step "Resetting MinIO config store (IAM users, groups, policies, access keys)..."

    if [[ ! -d "${config_dir}" ]]; then
        log_warn "Config store not found; nothing to reset."
        return 0
    fi

    log_info "Backing up current config to ${backup_dir}..."
    copy_path_elevated "${config_dir}" "${backup_dir}"
    remove_path_elevated "${config_dir}"
    log_success "Removed config store (backup: ${backup_dir})."
}

patch_credentials_env() {
    log_step "Updating root username in .env (other values unchanged)..."

    set_env_key_in_file "MINIO_ROOT_USER" "${MINIO_ROOT_USER}"
    # Legacy: make sure the password is not kept in .env.
    set_env_key_in_file "MINIO_ROOT_PASSWORD" ""

    log_success "Root username updated in .env"

    log_step "Updating docker-compose.yml and secrets/root_password..."
    generate_compose_file
}

mc_verify_credentials_once() {
    local err_log rc=0

    if ! container_is_running; then
        return 1
    fi

    err_log=$(mktemp)
    container_mc "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" "" ls "${MC_ALIAS}" >/dev/null 2>"${err_log}" || rc=$?

    if [[ "${rc}" -ne 0 && -s "${err_log}" ]]; then
        MC_LAST_ERROR="$(tail -n1 "${err_log}")"
    fi

    rm -f "${err_log}"
    return "${rc}"
}

verify_root_credentials() {
    local attempt=0
    local max_attempts=6

    MC_LAST_ERROR=""
    log_step "Verifying root credentials against MinIO API..."

    while [[ "${attempt}" -lt "${max_attempts}" ]]; do
        if mc_verify_credentials_once; then
            log_success "Root credentials verified successfully."
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "${attempt}" -lt "${max_attempts}" ]]; then
            log_info "Waiting for MinIO to accept credentials (${attempt}/${max_attempts})..."
            sleep 5
        fi
    done

    log_error "Credential verification failed."
    if [[ -n "${MC_LAST_ERROR:-}" ]]; then
        log_warn "Detail: ${MC_LAST_ERROR}"
    fi
    return 1
}
