#!/usr/bin/env bash
# Interactive main menu.

show_main_menu_banner() {
    echo ""
    echo -e "${BOLD}=========================================${NC}"
    echo -e "${BOLD}        MinIO Docker Setup Menu          ${NC}"
    echo -e "${BOLD}=========================================${NC}"
    echo ""
}

show_menu_options() {
    echo -e "  ${BOLD}1)${NC}  Install MinIO"
    echo -e "  ${BOLD}2)${NC}  Uninstall MinIO"
    echo -e "  ${BOLD}3)${NC}  Start"
    echo -e "  ${BOLD}4)${NC}  Stop"
    echo -e "  ${BOLD}5)${NC}  Restart"
    echo -e "  ${BOLD}6)${NC}  Status"
    echo -e "  ${BOLD}7)${NC}  Logs"
    echo -e "  ${BOLD}8)${NC}  Update"
    echo -e "  ${BOLD}9)${NC}  Backup"
    echo -e "  ${BOLD}10)${NC} Restore"
    echo -e "  ${BOLD}11)${NC} Update Public URLs"
    echo -e "  ${BOLD}0)${NC}  Exit"
    echo ""
}

pause_menu() {
    echo ""
    read -r -p "Press Enter to return to menu..."
}

run_interactive_menu() {
    local choice restore_path

    while true; do
        show_main_menu_banner
        show_menu_options

        read -r -p "Select action [0]: " choice
        choice="${choice:-0}"

        echo ""

        case "${choice}" in
            1)
                log_progress "Starting installation..."
                run_install_command || true
                pause_menu
                ;;
            2)
                log_progress "Starting uninstall..."
                run_uninstall_command || true
                pause_menu
                ;;
            3)
                run_command_from_menu start || true
                pause_menu
                ;;
            4)
                run_command_from_menu stop || true
                pause_menu
                ;;
            5)
                run_command_from_menu restart || true
                pause_menu
                ;;
            6)
                run_command_from_menu status || true
                pause_menu
                ;;
            7)
                log_info "Showing logs (Ctrl+C to return)..."
                run_command_from_menu logs || true
                echo ""
                ;;
            8)
                run_command_from_menu update || true
                pause_menu
                ;;
            9)
                run_command_from_menu backup || true
                pause_menu
                ;;
            10)
                read -r -p "Backup archive path (leave empty for prompt): " restore_path
                run_command_from_menu restore "${restore_path}" || true
                pause_menu
                ;;
            11)
                run_command_from_menu update-urls || true
                pause_menu
                ;;
            0)
                log_info "Goodbye."
                return 0
                ;;
            *)
                log_error "Invalid selection: ${choice}"
                pause_menu
                ;;
        esac
    done
}
