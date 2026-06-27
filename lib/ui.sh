#!/usr/bin/env bash
# Interactive UI prompts and banners.

show_banner() {
    echo ""
    echo -e "${BOLD}=========================================${NC}"
    echo -e "${BOLD}       MinIO Docker Installer            ${NC}"
    echo -e "${BOLD}=========================================${NC}"
    echo ""
}

show_install_complete() {
    local server_ip="$1"
    local api_endpoint="$2"
    local console_endpoint="$3"

    echo ""
    echo -e "${GREEN}${BOLD}=========================================${NC}"
    echo -e "${GREEN}${BOLD}       Installation Complete             ${NC}"
    echo -e "${GREEN}${BOLD}=========================================${NC}"
    echo ""
    echo -e "  ${BOLD}Container Name:${NC}    ${MINIO_CONTAINER_NAME}"
    echo -e "  ${BOLD}Storage Path:${NC}      ${MINIO_DATA_PATH}"
    echo -e "  ${BOLD}Docker Network:${NC}    ${MINIO_NETWORK:-minio-network}"
    echo -e "  ${BOLD}Expose Ports:${NC}      ${MINIO_EXPOSE_PORTS}"
    echo -e "  ${BOLD}Server IP:${NC}         ${server_ip}"

    if [[ "${MINIO_EXPOSE_PORTS}" == "true" ]]; then
        echo -e "  ${BOLD}API Endpoint:${NC}      ${api_endpoint}"
        echo -e "  ${BOLD}Console Endpoint:${NC}  ${console_endpoint}"
    else
        echo -e "  ${BOLD}API Endpoint:${NC}      Internal only (Docker network)"
        echo -e "  ${BOLD}Console Endpoint:${NC}  Internal only (Docker network)"
    fi

    echo -e "  ${BOLD}Username:${NC}          ${MINIO_ROOT_USER}"
    echo -e "  ${BOLD}Password:${NC}          ${MINIO_ROOT_PASSWORD}"
    echo -e "  ${BOLD}Bucket:${NC}            ${MINIO_BUCKET:-none}"
    echo -e "  ${BOLD}Data Directory:${NC}    ${MINIO_DATA_PATH}"
    echo ""
    echo -e "${YELLOW}Store your credentials securely. The password is shown once.${NC}"
    echo ""
}

collect_install_config() {
    local choice

    log_progress "Collecting installation configuration..."
    echo ""

    MINIO_CONTAINER_NAME=$(prompt_default "Container Name" "minio")
    while ! [[ "${MINIO_CONTAINER_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; do
        log_error "Invalid container name. Use alphanumeric characters, dots, hyphens, or underscores."
        MINIO_CONTAINER_NAME=$(prompt_default "Container Name" "minio")
    done
    echo "--------------------------------"

    MINIO_DATA_PATH=$(prompt_default "Storage Path" "/opt/minio/data")
    echo "--------------------------------"

    if prompt_yes_no "Expose MinIO to Host?" "Y"; then
        MINIO_EXPOSE_PORTS="true"

        while true; do
            MINIO_API_PORT=$(prompt_default "API Port" "9000")
            if validate_port "${MINIO_API_PORT}"; then
                break
            fi
        done

        while true; do
            MINIO_CONSOLE_PORT=$(prompt_default "Console Port" "9001")
            if validate_port "${MINIO_CONSOLE_PORT}"; then
                if [[ "${MINIO_CONSOLE_PORT}" == "${MINIO_API_PORT}" ]]; then
                    log_error "Console port must differ from API port."
                    continue
                fi
                break
            fi
        done
    else
        MINIO_EXPOSE_PORTS="false"
        MINIO_API_PORT="9000"
        MINIO_CONSOLE_PORT="9001"
    fi
    echo "--------------------------------"

    MINIO_ROOT_USER=$(prompt_default "Root Username" "minioadmin")
    echo "--------------------------------"

    echo "Password options:"
    echo "  1) Generate Random"
    echo "  2) Manual Input"
    read -r -p "Select option [1]: " choice
    choice="${choice:-1}"

    case "${choice}" in
        1)
            MINIO_ROOT_PASSWORD=$(generate_password 24)
            log_success "Generated secure password (24+ characters)."
            ;;
        2)
            while true; do
                read -r -s -p "Enter password (min 24 chars, mixed case, numbers, symbols): " MINIO_ROOT_PASSWORD
                echo ""
                read -r -s -p "Confirm password: " choice
                echo ""

                if [[ "${MINIO_ROOT_PASSWORD}" != "${choice}" ]]; then
                    log_error "Passwords do not match."
                    continue
                fi

                if validate_password "${MINIO_ROOT_PASSWORD}"; then
                    break
                fi
            done
            ;;
        *)
            die "Invalid password option."
            ;;
    esac
    echo "--------------------------------"

    MINIO_CREATE_BUCKET="false"
    MINIO_BUCKET=""

    if prompt_yes_no "Create Default Bucket?" "Y"; then
        MINIO_CREATE_BUCKET="true"
        MINIO_BUCKET=$(prompt_default "Bucket Name" "storage")
    fi

    echo ""
    export MINIO_CONTAINER_NAME MINIO_DATA_PATH MINIO_EXPOSE_PORTS
    export MINIO_API_PORT MINIO_CONSOLE_PORT MINIO_ROOT_USER MINIO_ROOT_PASSWORD
    export MINIO_CREATE_BUCKET MINIO_BUCKET
}

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [args]

Run without arguments to open the interactive menu.

Commands:
  install     Run interactive MinIO installation
  uninstall   Remove MinIO containers, network, and generated config
  start       Start MinIO containers
  stop        Stop MinIO containers
  restart     Restart MinIO containers
  logs        Tail MinIO container logs
  status      Show container and health status
  update      Pull latest MinIO image and recreate containers
  backup      Create compressed backup of config and data
  restore     Restore from a backup archive

Examples:
  ./setup.sh
  ./setup.sh install
  ./setup.sh status
  ./setup.sh backup
  ./setup.sh restore /path/to/backup.tar.gz
EOF
}
