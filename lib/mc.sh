#!/usr/bin/env bash
# MinIO Client (mc) helpers — shared session, idempotent bucket/IAM operations.

MC_ALIAS="${MC_ALIAS:-localminio}"

# Kept for API compatibility with callers: mc runs inside the MinIO container,
# so there is no client to download and no host-side config to set up.
mc_session_start() {
    if ! container_is_running; then
        log_error "Container '${MINIO_CONTAINER_NAME}' is not running."
        return 1
    fi
}

mc_session_end() {
    :
}

mc_cmd() {
    container_mc "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" "" "$@"
}

# mc_cmd_with_file HOST_FILE mc-args...  (file is appended as last argument)
mc_cmd_with_file() {
    local host_file="$1"
    shift

    container_mc "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" "${host_file}" "$@" /dev/stdin
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
    echo '      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],'
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
    echo '        "s3:DeleteObject",'
    echo '        "s3:AbortMultipartUpload",'
    echo '        "s3:ListMultipartUploadParts"'
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

    # Exactly 'download' (read-only). 'public' or 'upload' would allow
    # anonymous WRITES and must be replaced.
    if [[ "${current}" == *'`download`'* ]]; then
        log_info "Bucket '${bucket}' already allows anonymous download (read-only)."
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

    # 'policy create' overwrites an existing policy in place, so existing
    # attachments stay intact (no detach/remove window).
    if mc_policy_exists "${policy_name}"; then
        log_info "Policy '${policy_name}' already exists; updating in place..."
    fi

    if mc_cmd_with_file "${policy_file}" admin policy create "${MC_ALIAS}" "${policy_name}" >/dev/null; then
        log_success "Policy '${policy_name}' created/updated."
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

    # 'user add' updates the secret of an existing user. Never remove the user:
    # that would also delete its access keys / service accounts.
    if mc_user_exists "${username}"; then
        log_info "User '${username}' already exists; updating password (access keys are kept)..."
    fi

    # Pass the secret on stdin: arguments of processes inside the container
    # are visible to every user on the host via 'ps'.
    local secret_file rc=0
    secret_file=$(mktemp)
    chmod 600 "${secret_file}"
    printf '%s\n' "${password}" > "${secret_file}"
    container_mc "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" "${secret_file}" \
        admin user add "${MC_ALIAS}" "${username}" >/dev/null || rc=$?
    rm -f "${secret_file}"

    if [[ "${rc}" -eq 0 ]]; then
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

    local out=""

    if mc_cmd admin user info "${MC_ALIAS}" "${username}" --json 2>/dev/null | grep -q "\"${policy_name}\""; then
        log_info "Policy '${policy_name}' already attached to user '${username}'."
        return 0
    fi

    if out=$(mc_cmd admin policy attach "${MC_ALIAS}" "${policy_name}" --user "${username}" 2>&1); then
        log_success "Policy '${policy_name}' attached to user '${username}'."
        return 0
    fi

    if [[ "${out}" == *"already"* ]]; then
        log_info "Policy '${policy_name}' already attached to user '${username}'."
        return 0
    fi

    log_error "Failed to attach policy '${policy_name}' to user '${username}': ${out}"
    return 1
}

write_app_password_secret() {
    local secrets_dir="${PROJECT_ROOT}/secrets"
    local secret_file="${secrets_dir}/app_password"

    mkdir -p "${secrets_dir}"
    chmod 700 "${secrets_dir}"
    ( umask 077; printf '%s' "${MINIO_APP_PASSWORD}" > "${secret_file}" )
    chmod 600 "${secret_file}"
}
