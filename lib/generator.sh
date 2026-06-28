#!/usr/bin/env bash
# Generate .env and docker-compose.yml from templates.

replace_placeholder() {
    local line="$1"
    local token="$2"
    local value="$3"
    local result=""
    local before after

    while [[ "${line}" == *"${token}"* ]]; do
        before="${line%%"${token}"*}"
        after="${line#*"${token}"}"
        result+="${before}${value}"
        line="${after}"
    done

    result+="${line}"
    printf '%s' "${result}"
}

write_env_line() {
    local key="$1"
    local value="$2"

    if [[ -z "${value}" && "${key}" =~ ^(MINIO_SERVER_URL|MINIO_BROWSER_REDIRECT_URL|MINIO_BUCKETS|MINIO_PUBLIC_BUCKETS|MINIO_APP_USER)$ ]]; then
        return 0
    fi

    printf '%s=%s\n' "${key}" "$(quote_env_value "${value}")"
}

write_root_password_secret() {
    local secrets_dir="${PROJECT_ROOT}/secrets"
    local secret_file="${secrets_dir}/root_password"

    mkdir -p "${secrets_dir}"
    printf '%s' "${MINIO_ROOT_PASSWORD}" > "${secret_file}"
    chmod 600 "${secret_file}"
    chmod 700 "${secrets_dir}"
}

generate_env_file() {
    local template="${PROJECT_ROOT}/.env.tpl"
    local output="${PROJECT_ROOT}/.env"

    log_step "Generating .env configuration..."

    if [[ ! -f "${template}" ]]; then
        die "Template not found: ${template}"
    fi

    : > "${output}"

    write_env_line "MINIO_CONTAINER_NAME" "${MINIO_CONTAINER_NAME}" >> "${output}"
    write_env_line "MINIO_ROOT_USER" "${MINIO_ROOT_USER}" >> "${output}"
    write_env_line "MINIO_ROOT_PASSWORD" "${MINIO_ROOT_PASSWORD}" >> "${output}"
    write_env_line "MINIO_API_PORT" "${MINIO_API_PORT}" >> "${output}"
    write_env_line "MINIO_CONSOLE_PORT" "${MINIO_CONSOLE_PORT}" >> "${output}"
    write_env_line "MINIO_DATA_PATH" "${MINIO_DATA_PATH}" >> "${output}"
    write_env_line "MINIO_BUCKETS" "${MINIO_BUCKETS:-}" >> "${output}"
    write_env_line "MINIO_PUBLIC_BUCKETS" "${MINIO_PUBLIC_BUCKETS:-}" >> "${output}"
    write_env_line "MINIO_SETUP_APP_USER" "${MINIO_SETUP_APP_USER:-false}" >> "${output}"
    write_env_line "MINIO_APP_USER" "${MINIO_APP_USER:-}" >> "${output}"
    write_env_line "MINIO_EXPOSE_PORTS" "${MINIO_EXPOSE_PORTS}" >> "${output}"
    write_env_line "MINIO_NETWORK" "${MINIO_NETWORK:-minio-network}" >> "${output}"
    write_env_line "MINIO_SERVER_URL" "${MINIO_SERVER_URL:-}" >> "${output}"
    write_env_line "MINIO_BROWSER_REDIRECT_URL" "${MINIO_BROWSER_REDIRECT_URL:-}" >> "${output}"

    chmod 600 "${output}"
    log_success "Generated ${output}"
}

generate_compose_file() {
    local template="${PROJECT_ROOT}/docker-compose.yml.tpl"
    local output="${PROJECT_ROOT}/docker-compose.yml"
    local line
    local user_yaml secret_host_path

    log_step "Generating docker-compose.yml..."

    if [[ ! -f "${template}" ]]; then
        die "Template not found: ${template}"
    fi

    write_root_password_secret
    user_yaml=$(yaml_single_quote "${MINIO_ROOT_USER}")
    secret_host_path="${PROJECT_ROOT}/secrets/root_password"

    : > "${output}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == *'{{PORTS_SECTION}}'* ]]; then
            if [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
                {
                    printf '    ports:\n'
                    printf '      - "%s:9000"\n' "${MINIO_API_PORT}"
                    printf '      - "%s:9001"\n' "${MINIO_CONSOLE_PORT}"
                } >> "${output}"
            fi
            continue
        fi

        if [[ "${line}" == *'{{PUBLIC_URL_ENV_SECTION}}'* ]]; then
            if [[ -n "${MINIO_SERVER_URL:-}" ]]; then
                printf '      MINIO_SERVER_URL: %s\n' "$(yaml_single_quote "${MINIO_SERVER_URL}")" >> "${output}"
            fi
            if [[ -n "${MINIO_BROWSER_REDIRECT_URL:-}" ]]; then
                printf '      MINIO_BROWSER_REDIRECT_URL: %s\n' "$(yaml_single_quote "${MINIO_BROWSER_REDIRECT_URL}")" >> "${output}"
            fi
            continue
        fi

        line=$(replace_placeholder "${line}" '{{MINIO_CONTAINER_NAME}}' "${MINIO_CONTAINER_NAME}")
        line=$(replace_placeholder "${line}" '{{MINIO_DATA_PATH}}' "${MINIO_DATA_PATH}")
        line=$(replace_placeholder "${line}" '{{MINIO_NETWORK}}' "${MINIO_NETWORK:-minio-network}")
        line=$(replace_placeholder "${line}" '{{MINIO_ROOT_USER_YAML}}' "${user_yaml}")
        line=$(replace_placeholder "${line}" '{{MINIO_ROOT_PASSWORD_SECRET_PATH}}' "${secret_host_path}")
        printf '%s\n' "${line}" >> "${output}"
    done < "${template}"

    chmod 600 "${output}"
    log_success "Generated ${output}"
}

generate_config_files() {
    MINIO_NETWORK="${MINIO_NETWORK:-minio-network}"
    generate_env_file
    generate_compose_file
}

set_env_key_in_file() {
    local key="$1"
    local value="$2"
    local env_file="${PROJECT_ROOT}/.env"
    local tmp found=0 line

    if [[ ! -f "${env_file}" ]]; then
        die "Configuration not found: ${env_file}"
    fi

    tmp="$(mktemp "${env_file}.XXXXXX")"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ "${line}" == "${key}="* ]]; then
            found=1
            if [[ -n "${value}" ]]; then
                printf '%s=%s\n' "${key}" "$(quote_env_value "${value}")" >> "${tmp}"
            fi
            continue
        fi
        printf '%s\n' "${line}" >> "${tmp}"
    done < "${env_file}"

    if [[ "${found}" -eq 0 && -n "${value}" ]]; then
        printf '%s=%s\n' "${key}" "$(quote_env_value "${value}")" >> "${tmp}"
    fi

    mv "${tmp}" "${env_file}"
    chmod 600 "${env_file}"
}

patch_public_url_env() {
    log_step "Updating public URL entries in .env (other values unchanged)..."

    set_env_key_in_file "MINIO_SERVER_URL" "${MINIO_SERVER_URL:-}"
    set_env_key_in_file "MINIO_BROWSER_REDIRECT_URL" "${MINIO_BROWSER_REDIRECT_URL:-}"

    log_success "Public URL entries updated in .env"
}

update_public_url_config() {
    log_progress "Updating public URL configuration..."
    patch_public_url_env
    generate_compose_file
}
