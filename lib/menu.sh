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
    echo -e "  ${BOLD}8)${NC}  Update Image"
    echo -e "  ${BOLD}9)${NC}  Backup"
    echo -e "  ${BOLD}10)${NC} Restore"
    echo -e "  ${BOLD}11)${NC} Update Public URLs"
    echo -e "  ${BOLD}12)${NC} Reset Root Password"
    echo -e "  ${BOLD}13)${NC} Diagnose Login Issues"
    echo -e "  ${BOLD}14)${NC} Manage Buckets & User Access"
    echo -e "  ${BOLD}15)${NC} Check for Silo Update"
    echo -e "  ${BOLD}16)${NC} Auto-Update Settings"
    echo -e "  ${BOLD}0)${NC}  Exit"
    echo ""
}

# Run a menu action in a subshell so 'die' or Ctrl+C returns to the menu
# instead of terminating the whole program.
#
# The subshell must NOT be part of an '||'/'if' list: bash would then ignore
# 'set -e' for everything inside it and keep going after failures.
menu_action() {
    trap - ERR
    set +e
    ( install_err_trap; set -e; "$@" )
    set -e
    install_err_trap
    return 0
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
                menu_action run_install_command
                pause_menu
                ;;
            2)
                log_progress "Starting uninstall..."
                menu_action run_uninstall_command
                pause_menu
                ;;
            3)
                menu_action run_command_from_menu start
                pause_menu
                ;;
            4)
                menu_action run_command_from_menu stop
                pause_menu
                ;;
            5)
                menu_action run_command_from_menu restart
                pause_menu
                ;;
            6)
                menu_action run_command_from_menu status
                pause_menu
                ;;
            7)
                log_info "Showing recent logs (use: ./setup.sh logs -f to follow)..."
                menu_action run_command_from_menu logs
                pause_menu
                ;;
            8)
                menu_action run_command_from_menu update
                pause_menu
                ;;
            9)
                menu_action run_command_from_menu backup
                pause_menu
                ;;
            10)
                read -r -p "Backup archive path (leave empty for prompt): " restore_path
                menu_action run_command_from_menu restore "${restore_path}"
                pause_menu
                ;;
            11)
                menu_action run_command_from_menu update-urls
                pause_menu
                ;;
            12)
                menu_action run_command_from_menu reset-password
                pause_menu
                ;;
            13)
                menu_action run_command_from_menu diagnose
                pause_menu
                ;;
            14)
                menu_action run_command_from_menu manage-access
                pause_menu
                ;;
            15)
                menu_action run_command_from_menu check-update
                pause_menu
                ;;
            16)
                menu_action run_command_from_menu auto-update status
                if prompt_yes_no "Enable/reconfigure auto-update?" "N"; then
                    menu_action run_command_from_menu auto-update enable
                elif prompt_yes_no "Disable auto-update?" "N"; then
                    menu_action run_command_from_menu auto-update disable
                fi
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
