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

generate_env_file() {
    local template="${PROJECT_ROOT}/.env.tpl"
    local output="${PROJECT_ROOT}/.env"
    local line

    log_step "Generating .env configuration..."

    if [[ ! -f "${template}" ]]; then
        die "Template not found: ${template}"
    fi

    : > "${output}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=$(replace_placeholder "${line}" '{{MINIO_CONTAINER_NAME}}' "${MINIO_CONTAINER_NAME}")
        line=$(replace_placeholder "${line}" '{{MINIO_ROOT_USER}}' "${MINIO_ROOT_USER}")
        line=$(replace_placeholder "${line}" '{{MINIO_ROOT_PASSWORD}}' "${MINIO_ROOT_PASSWORD}")
        line=$(replace_placeholder "${line}" '{{MINIO_API_PORT}}' "${MINIO_API_PORT}")
        line=$(replace_placeholder "${line}" '{{MINIO_CONSOLE_PORT}}' "${MINIO_CONSOLE_PORT}")
        line=$(replace_placeholder "${line}" '{{MINIO_DATA_PATH}}' "${MINIO_DATA_PATH}")
        line=$(replace_placeholder "${line}" '{{MINIO_BUCKET}}' "${MINIO_BUCKET:-}")
        line=$(replace_placeholder "${line}" '{{MINIO_EXPOSE_PORTS}}' "${MINIO_EXPOSE_PORTS}")
        line=$(replace_placeholder "${line}" '{{MINIO_NETWORK}}' "${MINIO_NETWORK:-minio-network}")
        line=$(replace_placeholder "${line}" '{{MINIO_CREATE_BUCKET}}' "${MINIO_CREATE_BUCKET:-false}")
        printf '%s\n' "${line}" >> "${output}"
    done < "${template}"

    chmod 600 "${output}"
    log_success "Generated ${output}"
}

generate_compose_file() {
    local template="${PROJECT_ROOT}/docker-compose.yml.tpl"
    local output="${PROJECT_ROOT}/docker-compose.yml"
    local line

    log_step "Generating docker-compose.yml..."

    if [[ ! -f "${template}" ]]; then
        die "Template not found: ${template}"
    fi

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

        line=$(replace_placeholder "${line}" '{{MINIO_CONTAINER_NAME}}' "${MINIO_CONTAINER_NAME}")
        line=$(replace_placeholder "${line}" '{{MINIO_DATA_PATH}}' "${MINIO_DATA_PATH}")
        line=$(replace_placeholder "${line}" '{{MINIO_NETWORK}}' "${MINIO_NETWORK:-minio-network}")
        printf '%s\n' "${line}" >> "${output}"
    done < "${template}"

    log_success "Generated ${output}"
}

generate_config_files() {
    MINIO_NETWORK="${MINIO_NETWORK:-minio-network}"
    generate_env_file
    generate_compose_file
}
