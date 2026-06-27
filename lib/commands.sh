#!/usr/bin/env bash
# Command dispatcher for CLI and menu actions.

dispatch_command() {
    local command="${1:-}"
    local arg="${2:-}"

    case "${command}" in
        install)
            run_install_command
            ;;
        uninstall)
            run_uninstall_command
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart
            ;;
        logs)
            cmd_logs
            ;;
        status)
            cmd_status
            ;;
        update)
            cmd_update
            ;;
        backup)
            run_backup
            ;;
        restore)
            run_restore "${arg}"
            ;;
        help|-h|--help)
            show_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_usage
            return 1
            ;;
    esac
}

run_command_from_menu() {
    local action="$1"
    local restore_path="${2:-}"

    case "${action}" in
        install)       run_install_command ;;
        uninstall)     run_uninstall_command ;;
        start)         cmd_start ;;
        stop)          cmd_stop ;;
        restart)       cmd_restart ;;
        logs)          cmd_logs ;;
        status)        cmd_status ;;
        update)        cmd_update ;;
        backup)        run_backup ;;
        restore)       run_restore "${restore_path}" ;;
        *)
            log_error "Unknown menu action: ${action}"
            return 1
            ;;
    esac
}
