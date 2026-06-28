#!/usr/bin/env bash
# Bucket, application user, and IAM policy management.

collect_app_user_password() {
    local choice

    echo "Application user password options:"
    echo "  1) Generate Random"
    echo "  2) Manual Input"
    read -r -p "Select option [1]: " choice
    choice="${choice:-1}"

    case "${choice}" in
        1)
            MINIO_APP_PASSWORD=$(generate_password 24)
            log_success "Generated secure application password (24+ alphanumeric characters)."
            ;;
        2)
            while true; do
                read -r -s -p "Enter application password (min 24 chars, letters and numbers only): " MINIO_APP_PASSWORD
                echo ""
                read -r -s -p "Confirm password: " choice
                echo ""

                if [[ "${MINIO_APP_PASSWORD}" != "${choice}" ]]; then
                    log_error "Passwords do not match."
                    continue
                fi

                if validate_password "${MINIO_APP_PASSWORD}"; then
                    break
                fi
            done
            ;;
        *)
            die "Invalid password option."
            ;;
    esac
}

collect_buckets_interactive() {
    local bucket buckets=()
    local add_more="Y"

    echo ""
    log_info "Enter bucket names to create (one per line, empty line to finish)."

    while true; do
        read -r -p "Bucket name (or Enter to finish): " bucket
        bucket="${bucket#"${bucket%%[![:space:]]*}"}"
        bucket="${bucket%"${bucket##*[![:space:]]}"}"

        if [[ -z "${bucket}" ]]; then
            break
        fi

        if ! validate_bucket_name "${bucket}"; then
            continue
        fi

        if bucket_in_list "${bucket}" "${buckets[@]}"; then
            log_warn "Bucket '${bucket}' already in list; skipping duplicate."
            continue
        fi

        buckets+=("${bucket}")
        log_success "Added bucket '${bucket}'."
    done

    if [[ ${#buckets[@]} -eq 0 ]]; then
        if prompt_yes_no "No buckets entered. Add default bucket 'storage'?" "Y"; then
            buckets=("storage")
        fi
    fi

    MINIO_BUCKETS_ARRAY=("${buckets[@]}")
    MINIO_BUCKETS="$(array_to_csv "${buckets[@]}")"
}

merge_bucket_lists() {
    local -a merged=()
    local bucket

    for bucket in "$@"; do
        [[ -z "${bucket}" ]] && continue
        if ! bucket_in_list "${bucket}" "${merged[@]}"; then
            merged+=("${bucket}")
        fi
    done

    MINIO_BUCKETS_ARRAY=("${merged[@]}")
    MINIO_BUCKETS="$(array_to_csv "${merged[@]}")"
}

collect_public_buckets_interactive() {
    local mode="${1:-install}"
    shift
    local buckets=("$@")
    local selection item idx num public=()
    local -a chosen=()
    local -a saved_public=("${MINIO_PUBLIC_BUCKETS_ARRAY[@]}")
    local default_choice="n"

    if [[ ${#buckets[@]} -eq 0 ]]; then
        MINIO_PUBLIC_BUCKETS=""
        MINIO_PUBLIC_BUCKETS_ARRAY=()
        return 0
    fi

    if [[ "${mode}" == "manage" ]]; then
        default_choice="k"
    else
        MINIO_PUBLIC_BUCKETS_ARRAY=()
    fi

    echo ""
    log_info "Select buckets for anonymous (public) read access:"
    for idx in "${!buckets[@]}"; do
        echo "  $((idx + 1))) ${buckets[$idx]}"
    done
    echo "  a) All buckets"
    echo "  n) None"
    if [[ "${mode}" == "manage" && ${#saved_public[@]} -gt 0 ]]; then
        echo "  k) Keep current ($(array_to_csv "${saved_public[@]}"))"
    elif [[ "${mode}" == "manage" ]]; then
        echo "  k) Keep current (none)"
    fi
    echo ""

    read -r -p "Selection (numbers separated by commas, a, n${mode:+}, k}) [${default_choice}]: " selection
    selection="${selection:-${default_choice}}"
    selection="${selection// /}"

    case "${selection}" in
        k|K)
            if [[ "${mode}" == "manage" ]]; then
                MINIO_PUBLIC_BUCKETS_ARRAY=("${saved_public[@]}")
                MINIO_PUBLIC_BUCKETS="$(array_to_csv "${saved_public[@]}")"
            fi
            return 0
            ;;
        n|N|"")
            MINIO_PUBLIC_BUCKETS=""
            MINIO_PUBLIC_BUCKETS_ARRAY=()
            return 0
            ;;
        a|A)
            MINIO_PUBLIC_BUCKETS_ARRAY=("${buckets[@]}")
            MINIO_PUBLIC_BUCKETS="$(array_to_csv "${buckets[@]}")"
            return 0
            ;;
    esac

    IFS=',' read -ra chosen <<< "${selection}"
    for item in "${chosen[@]}"; do
        if [[ ! "${item}" =~ ^[0-9]+$ ]]; then
            log_warn "Ignoring invalid selection: ${item}"
            continue
        fi

        num=$((item - 1))
        if [[ "${num}" -lt 0 || "${num}" -ge ${#buckets[@]} ]]; then
            log_warn "Ignoring out-of-range selection: ${item}"
            continue
        fi

        if ! bucket_in_list "${buckets[$num]}" "${public[@]}"; then
            public+=("${buckets[$num]}")
        fi
    done

    MINIO_PUBLIC_BUCKETS_ARRAY=("${public[@]}")
    MINIO_PUBLIC_BUCKETS="$(array_to_csv "${public[@]}")"
}

collect_access_config() {
    local setup_user="${1:-true}"

    MINIO_BUCKETS_ARRAY=()
    MINIO_PUBLIC_BUCKETS_ARRAY=()
    MINIO_BUCKETS=""
    MINIO_PUBLIC_BUCKETS=""
    MINIO_SETUP_APP_USER="false"
    MINIO_APP_USER=""
    MINIO_APP_PASSWORD=""

    if ! prompt_yes_no "Create buckets during setup?" "Y"; then
        if [[ "${setup_user}" == "true" ]] && prompt_yes_no "Create application user anyway (requires at least one bucket)?" "N"; then
            setup_user="true"
        else
            return 0
        fi
    fi

    collect_buckets_interactive

    if [[ ${#MINIO_BUCKETS_ARRAY[@]} -eq 0 ]]; then
        log_warn "No buckets configured."
        return 0
    fi

    collect_public_buckets_interactive "install" "${MINIO_BUCKETS_ARRAY[@]}"

    if [[ "${setup_user}" != "true" ]]; then
        return 0
    fi

    echo "--------------------------------"

    if prompt_yes_no "Create application user with bucket-scoped IAM policy?" "Y"; then
        MINIO_SETUP_APP_USER="true"

        while true; do
            MINIO_APP_USER=$(prompt_default "Application Username" "app-user")
            if validate_app_username "${MINIO_APP_USER}"; then
                break
            fi
        done

        collect_app_user_password
    fi
}

persist_access_config() {
    set_env_key_in_file "MINIO_BUCKETS" "${MINIO_BUCKETS:-}"
    set_env_key_in_file "MINIO_PUBLIC_BUCKETS" "${MINIO_PUBLIC_BUCKETS:-}"
    set_env_key_in_file "MINIO_SETUP_APP_USER" "${MINIO_SETUP_APP_USER:-false}"
    set_env_key_in_file "MINIO_APP_USER" "${MINIO_APP_USER:-}"

    if [[ "${MINIO_SETUP_APP_USER:-false}" == "true" && -n "${MINIO_APP_PASSWORD:-}" ]]; then
        write_app_password_secret
    fi
}

apply_buckets_and_access() {
    local buckets=() public_buckets=() private_buckets=()
    local bucket policy_name policy_file failed=0

    buckets_to_array "${MINIO_BUCKETS:-}" buckets
    buckets_to_array "${MINIO_PUBLIC_BUCKETS:-}" public_buckets

    if [[ ${#buckets[@]} -eq 0 && "${MINIO_SETUP_APP_USER:-false}" != "true" ]]; then
        log_info "No buckets or application user to configure."
        return 0
    fi

    if [[ ${#buckets[@]} -eq 0 && "${MINIO_SETUP_APP_USER:-false}" == "true" ]]; then
        die "Application user requires at least one bucket."
    fi

    if ! wait_for_minio_ready; then
        return 1
    fi

    if ! mc_session_start; then
        return 1
    fi

    for bucket in "${buckets[@]}"; do
        mc_ensure_bucket "${bucket}" || failed=1
    done

    for bucket in "${buckets[@]}"; do
        if bucket_in_list "${bucket}" "${public_buckets[@]}"; then
            mc_set_public_read "${bucket}" || failed=1
        else
            mc_remove_public_access "${bucket}" || failed=1
        fi
    done

    if [[ "${MINIO_SETUP_APP_USER:-false}" == "true" ]]; then
        if [[ -z "${MINIO_APP_USER:-}" ]]; then
            mc_session_end
            die "MINIO_APP_USER is not set."
        fi

        if [[ -z "${MINIO_APP_PASSWORD:-}" ]]; then
            local secret_file="${PROJECT_ROOT}/secrets/app_password"
            if [[ -f "${secret_file}" ]]; then
                MINIO_APP_PASSWORD=$(<"${secret_file}")
            else
                mc_session_end
                die "Application user password is required."
            fi
        fi

        policy_name="$(app_policy_name "${MINIO_APP_USER}")"
        policy_file=$(mktemp)

        generate_app_policy_json "${buckets[@]}" > "${policy_file}"
        mc_ensure_policy "${policy_name}" "${policy_file}" || failed=1
        rm -f "${policy_file}"

        mc_ensure_user "${MINIO_APP_USER}" "${MINIO_APP_PASSWORD}" || failed=1
        mc_attach_user_policy "${policy_name}" "${MINIO_APP_USER}" || failed=1
        write_app_password_secret
    fi

    mc_session_end

    if [[ "${failed}" -ne 0 ]]; then
        log_warn "Some bucket or access operations encountered issues."
        return 1
    fi

    log_success "Bucket and access configuration applied."
    return 0
}

list_private_buckets() {
    local buckets=() public_buckets=() bucket

    buckets_to_array "${MINIO_BUCKETS:-}" buckets
    buckets_to_array "${MINIO_PUBLIC_BUCKETS:-}" public_buckets

    for bucket in "${buckets[@]}"; do
        if ! bucket_in_list "${bucket}" "${public_buckets[@]}"; then
            echo "${bucket}"
        fi
    done
}

show_access_summary() {
    local server_ip="$1"
    local api_endpoint="$2"
    local console_endpoint="$3"
    local public_display private_display private_list=()

    public_display="${MINIO_PUBLIC_BUCKETS:-none}"
    [[ -z "${MINIO_PUBLIC_BUCKETS:-}" ]] && public_display="none"

    mapfile -t private_list < <(list_private_buckets)
    if [[ ${#private_list[@]} -eq 0 ]]; then
        private_display="none"
    else
        private_display="$(array_to_csv "${private_list[@]}")"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}=========================================${NC}"
    echo -e "${GREEN}${BOLD}       Access Configuration Summary      ${NC}"
    echo -e "${GREEN}${BOLD}=========================================${NC}"
    echo ""
    echo -e "  ${BOLD}Root Admin Username:${NC}   ${MINIO_ROOT_USER}"
    if [[ "${MINIO_SETUP_APP_USER:-false}" == "true" && -n "${MINIO_APP_USER:-}" ]]; then
        echo -e "  ${BOLD}Application Username:${NC}  ${MINIO_APP_USER}"
    else
        echo -e "  ${BOLD}Application Username:${NC}  (not configured)"
    fi
    echo -e "  ${BOLD}Public Buckets:${NC}        ${public_display}"
    echo -e "  ${BOLD}Private Buckets:${NC}       ${private_display}"
    echo -e "  ${BOLD}API Endpoint:${NC}          ${api_endpoint}"
    echo -e "  ${BOLD}Console Endpoint:${NC}      ${console_endpoint}"

    if [[ -n "${MINIO_SERVER_URL:-}" || -n "${MINIO_BROWSER_REDIRECT_URL:-}" ]]; then
        echo ""
        echo -e "  ${BOLD}Public API URL:${NC}        ${MINIO_SERVER_URL:-not set}"
        echo -e "  ${BOLD}Public Console URL:${NC}    ${MINIO_BROWSER_REDIRECT_URL:-not set}"
    fi

    if [[ "${MINIO_SETUP_APP_USER:-false}" == "true" && -n "${MINIO_APP_PASSWORD:-}" ]]; then
        echo ""
        echo -e "  ${BOLD}Application Password:${NC}  ${MINIO_APP_PASSWORD}"
        echo -e "${YELLOW}Store application credentials securely. The password is shown once.${NC}"
    fi

    echo ""
}

show_manage_access_banner() {
    echo ""
    echo -e "${BOLD}=========================================${NC}"
    echo -e "${BOLD}   Manage Buckets & User Access          ${NC}"
    echo -e "${BOLD}=========================================${NC}"
    echo ""
}

show_manage_access_menu() {
    echo -e "  ${BOLD}1)${NC}  Configure buckets and public access"
    echo -e "  ${BOLD}2)${NC}  Create or update application user"
    echo -e "  ${BOLD}3)${NC}  Apply full access setup (buckets + user + policy)"
    echo -e "  ${BOLD}4)${NC}  Show current access summary"
    echo -e "  ${BOLD}0)${NC}  Back to main menu"
    echo ""
}

ensure_minio_running_for_access() {
    load_env_file

    if ! docker ps --format '{{.Names}}' | grep -qx "${MINIO_CONTAINER_NAME}"; then
        log_warn "MinIO is not running. Starting container..."
        compose_cmd up -d
    fi

    if ! wait_for_healthy "${MINIO_CONTAINER_NAME}"; then
        die "MinIO is not healthy. Check logs with: ./setup.sh logs"
    fi
}

run_manage_access_wizard() {
    local mode="${1:-full}"

    ensure_minio_running_for_access
    show_manage_access_banner

    buckets_to_array "${MINIO_BUCKETS:-}" MINIO_BUCKETS_ARRAY
    buckets_to_array "${MINIO_PUBLIC_BUCKETS:-}" MINIO_PUBLIC_BUCKETS_ARRAY

    case "${mode}" in
        buckets)
            local existing=("${MINIO_BUCKETS_ARRAY[@]}")
            if [[ ${#existing[@]} -gt 0 ]]; then
                log_info "Current buckets: $(array_to_csv "${existing[@]}")"
            fi
            collect_buckets_interactive
            merge_bucket_lists "${existing[@]}" "${MINIO_BUCKETS_ARRAY[@]}"
            if [[ ${#MINIO_BUCKETS_ARRAY[@]} -gt 0 ]]; then
                collect_public_buckets_interactive "manage" "${MINIO_BUCKETS_ARRAY[@]}"
            fi
            ;;
        user)
            if [[ ${#MINIO_BUCKETS_ARRAY[@]} -eq 0 ]]; then
                log_warn "No buckets configured yet."
                collect_buckets_interactive
                collect_public_buckets_interactive "install" "${MINIO_BUCKETS_ARRAY[@]}"
            fi

            MINIO_SETUP_APP_USER="true"
            while true; do
                MINIO_APP_USER=$(prompt_default "Application Username" "${MINIO_APP_USER:-app-user}")
                if validate_app_username "${MINIO_APP_USER}"; then
                    break
                fi
            done
            collect_app_user_password
            ;;
        full)
            collect_access_config "true"
            ;;
        summary)
            show_access_summary "$(get_primary_ip)" \
                "$(access_api_endpoint)" "$(access_console_endpoint)"
            return 0
            ;;
        *)
            die "Unknown manage-access mode: ${mode}"
            ;;
    esac

    if [[ ${#MINIO_BUCKETS_ARRAY[@]} -eq 0 && "${MINIO_SETUP_APP_USER:-false}" != "true" ]]; then
        log_info "No changes to apply."
        return 0
    fi

    persist_access_config
    apply_buckets_and_access || log_warn "Some operations may need review."

    show_access_summary "$(get_primary_ip)" \
        "$(access_api_endpoint)" "$(access_console_endpoint)"
}

access_api_endpoint() {
    if [[ -n "${MINIO_SERVER_URL:-}" ]]; then
        echo "${MINIO_SERVER_URL}"
    elif [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        echo "http://$(get_primary_ip):${MINIO_API_PORT}"
    else
        echo "Internal (Docker network: ${MINIO_NETWORK:-minio-network})"
    fi
}

access_console_endpoint() {
    if [[ -n "${MINIO_BROWSER_REDIRECT_URL:-}" ]]; then
        echo "${MINIO_BROWSER_REDIRECT_URL}"
    elif [[ "${MINIO_EXPOSE_PORTS:-false}" == "true" ]]; then
        echo "http://$(get_primary_ip):${MINIO_CONSOLE_PORT}"
    else
        echo "Internal (Docker network: ${MINIO_NETWORK:-minio-network})"
    fi
}

run_manage_access_menu() {
    local choice

    while true; do
        show_manage_access_banner
        show_manage_access_menu

        read -r -p "Select action [0]: " choice
        choice="${choice:-0}"
        echo ""

        case "${choice}" in
            1)
                run_manage_access_wizard "buckets" || true
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            2)
                run_manage_access_wizard "user" || true
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            3)
                run_manage_access_wizard "full" || true
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            4)
                ensure_minio_running_for_access
                show_access_summary "$(get_primary_ip)" \
                    "$(access_api_endpoint)" "$(access_console_endpoint)"
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            0)
                return 0
                ;;
            *)
                log_error "Invalid selection: ${choice}"
                ;;
        esac
    done
}

run_manage_access_command() {
    if [[ $# -gt 0 && -n "${1}" ]]; then
        case "${1}" in
            buckets) run_manage_access_wizard "buckets" ;;
            user)    run_manage_access_wizard "user" ;;
            full)    run_manage_access_wizard "full" ;;
            summary) run_manage_access_wizard "summary" ;;
            *)
                log_error "Unknown manage-access mode: ${1}"
                echo "Usage: ./setup.sh manage-access [buckets|user|full|summary]"
                return 1
                ;;
        esac
        return 0
    fi

    run_manage_access_menu
}
