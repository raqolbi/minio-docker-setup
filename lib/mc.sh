#!/usr/bin/env bash
# MinIO Client (mc) helpers — shared session, idempotent bucket/IAM operations.

MC_ALIAS="${MC_ALIAS:-localminio}"
MC_SESSION_CONFIG=""

mc_endpoint() {
    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        echo "http://127.0.0.1:${MINIO_API_PORT}"
    else
        echo "http://${MINIO_CONTAINER_NAME}:9000"
    fi
}

mc_session_start() {
    local endpoint

    endpoint="$(mc_endpoint)"

    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        ensure_mc_client
        if ! "${MC_BIN}" alias set "${MC_ALIAS}" "${endpoint}" \
            "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null; then
            log_error "Failed to configure mc alias against ${endpoint}."
            return 1
        fi
        return 0
    fi

    MC_SESSION_CONFIG=$(mktemp -d)
    if ! docker run --rm --network "${MINIO_NETWORK}" \
        -v "${MC_SESSION_CONFIG}:/root/.mc" \
        minio/mc:latest alias set "${MC_ALIAS}" "${endpoint}" \
        "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null; then
        log_error "Failed to configure mc alias against ${endpoint} (Docker network)."
        mc_session_end
        return 1
    fi
}

mc_session_end() {
    if [[ -n "${MC_SESSION_CONFIG}" && -d "${MC_SESSION_CONFIG}" ]]; then
        rm -rf "${MC_SESSION_CONFIG}"
    fi
    MC_SESSION_CONFIG=""
}

mc_cmd() {
    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        "${MC_BIN}" "$@"
    else
        docker run --rm --network "${MINIO_NETWORK}" \
            -v "${MC_SESSION_CONFIG}:/root/.mc" \
            minio/mc:latest "$@"
    fi
}

mc_cmd_with_file() {
    local host_file="$1"
    shift
    local container_path="/tmp/mc-input.json"

    if [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        "${MC_BIN}" "$@" "${host_file}"
    else
        docker run --rm --network "${MINIO_NETWORK}" \
            -v "${MC_SESSION_CONFIG}:/root/.mc" \
            -v "${host_file}:${container_path}:ro" \
            minio/mc:latest "$@" "${container_path}"
    fi
}

wait_for_minio_ready() {
    local timeout="${1:-120}"
    local elapsed=0

    log_step "Waiting for MinIO API before running mc commands..."

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        if check_api_internal && mc_verify_credentials_once; then
            log_success "MinIO is ready for mc operations."
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
        log_info "MinIO not ready yet (${elapsed}s elapsed)..."
    done

    log_error "Timed out waiting for MinIO to accept mc commands."
    return 1
}

buckets_to_array() {
    local csv="$1"
    local -n _out=$2
    local item

    _out=()
    [[ -z "${csv}" ]] && return 0

    IFS=',' read -ra _raw <<< "${csv}"
    for item in "${_raw[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "${item}" ]] && _out+=("${item}")
    done
}

array_to_csv() {
    local arr=("$@")
    local IFS=','

    echo "${arr[*]}"
}

bucket_in_list() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done

    return 1
}

generate_app_policy_json() {
    local buckets=("$@")
    local bucket first=1

    if [[ ${#buckets[@]} -eq 0 ]]; then
        die "Cannot generate IAM policy without buckets."
    fi

    echo '{'
    echo '  "Version": "2012-10-17",'
    echo '  "Statement": ['
    echo '    {'
    echo '      "Effect": "Allow",'
    echo '      "Action": ["s3:ListBucket"],'
    echo '      "Resource": ['

    first=1
    for bucket in "${buckets[@]}"; do
        if [[ "${first}" -eq 1 ]]; then
            printf '        "arn:aws:s3:::%s"' "${bucket}"
            first=0
        else
            printf ',\n        "arn:aws:s3:::%s"' "${bucket}"
        fi
    done
    echo ''
    echo '      ]'
    echo '    },'
    echo '    {'
    echo '      "Effect": "Allow",'
    echo '      "Action": ['
    echo '        "s3:GetObject",'
    echo '        "s3:PutObject",'
    echo '        "s3:DeleteObject"'
    echo '      ],'
    echo '      "Resource": ['

    first=1
    for bucket in "${buckets[@]}"; do
        if [[ "${first}" -eq 1 ]]; then
            printf '        "arn:aws:s3:::%s/*"' "${bucket}"
            first=0
        else
            printf ',\n        "arn:aws:s3:::%s/*"' "${bucket}"
        fi
    done
    echo ''
    echo '      ]'
    echo '    }'
    echo '  ]'
    echo '}'
}

app_policy_name() {
    local user="${1:-${MINIO_APP_USER}}"
    local safe="${user//[^a-zA-Z0-9_-]/_}"

    echo "${safe}-bucket-access"
}

mc_bucket_exists() {
    local bucket="$1"

    mc_cmd ls "${MC_ALIAS}/${bucket}" &>/dev/null
}

mc_ensure_bucket() {
    local bucket="$1"

    if mc_bucket_exists "${bucket}"; then
        log_info "Bucket '${bucket}' already exists."
        return 0
    fi

    if mc_cmd mb "${MC_ALIAS}/${bucket}"; then
        log_success "Bucket '${bucket}' created."
        return 0
    fi

    log_error "Failed to create bucket '${bucket}'."
    return 1
}

mc_set_public_read() {
    local bucket="$1"
    local current=""

    current=$(mc_cmd anonymous get "${MC_ALIAS}/${bucket}" 2>/dev/null || true)

    if [[ "${current}" == *"download"* || "${current}" == *"public"* ]]; then
        log_info "Bucket '${bucket}' already allows anonymous download."
        return 0
    fi

    if mc_cmd anonymous set download "${MC_ALIAS}/${bucket}"; then
        log_success "Anonymous download enabled for bucket '${bucket}'."
        return 0
    fi

    log_error "Failed to set anonymous download on bucket '${bucket}'."
    return 1
}

mc_remove_public_access() {
    local bucket="$1"
    local current=""

    current=$(mc_cmd anonymous get "${MC_ALIAS}/${bucket}" 2>/dev/null || true)

    if [[ -z "${current}" || "${current}" == *"none"* || "${current}" == *"private"* ]]; then
        log_info "Bucket '${bucket}' is already private."
        return 0
    fi

    if mc_cmd anonymous set none "${MC_ALIAS}/${bucket}"; then
        log_success "Anonymous access removed from bucket '${bucket}'."
        return 0
    fi

    log_error "Failed to remove anonymous access from bucket '${bucket}'."
    return 1
}

mc_policy_exists() {
    local policy_name="$1"

    mc_cmd admin policy info "${MC_ALIAS}" "${policy_name}" &>/dev/null
}

mc_ensure_policy() {
    local policy_name="$1"
    local policy_file="$2"

    if mc_policy_exists "${policy_name}"; then
        log_info "Policy '${policy_name}' already exists; updating..."
        mc_cmd admin policy detach "${MC_ALIAS}" "${policy_name}" --user "${MINIO_APP_USER}" &>/dev/null || true
        mc_cmd admin policy remove "${MC_ALIAS}" "${policy_name}" &>/dev/null || true
    fi

    if mc_cmd_with_file "${policy_file}" admin policy create "${MC_ALIAS}" "${policy_name}"; then
        log_success "Policy '${policy_name}' created."
        return 0
    fi

    log_error "Failed to create policy '${policy_name}'."
    return 1
}

mc_user_exists() {
    local username="$1"

    mc_cmd admin user info "${MC_ALIAS}" "${username}" &>/dev/null
}

mc_ensure_user() {
    local username="$1"
    local password="$2"

    if mc_user_exists "${username}"; then
        log_info "User '${username}' already exists; updating credentials..."
        mc_cmd admin user remove "${MC_ALIAS}" "${username}" &>/dev/null || true
    fi

    if mc_cmd admin user add "${MC_ALIAS}" "${username}" "${password}"; then
        mc_cmd admin user enable "${MC_ALIAS}" "${username}" &>/dev/null || true
        log_success "User '${username}' configured."
        return 0
    fi

    log_error "Failed to configure user '${username}'."
    return 1
}

mc_attach_user_policy() {
    local policy_name="$1"
    local username="$2"

    mc_cmd admin policy detach "${MC_ALIAS}" "${policy_name}" --user "${username}" &>/dev/null || true

    if mc_cmd admin policy attach "${MC_ALIAS}" "${policy_name}" --user "${username}"; then
        log_success "Policy '${policy_name}' attached to user '${username}'."
        return 0
    fi

    log_error "Failed to attach policy '${policy_name}' to user '${username}'."
    return 1
}

write_app_password_secret() {
    local secrets_dir="${PROJECT_ROOT}/secrets"
    local secret_file="${secrets_dir}/app_password"

    mkdir -p "${secrets_dir}"
    printf '%s' "${MINIO_APP_PASSWORD}" > "${secret_file}"
    chmod 600 "${secret_file}"
    chmod 700 "${secrets_dir}"
}
