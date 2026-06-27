#!/usr/bin/env bash
#
# MinIO Docker Setup
# Production-ready interactive installer for Ubuntu Server 22.04+
#
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT

# shellcheck source=lib/bootstrap.sh
source "${PROJECT_ROOT}/lib/bootstrap.sh"
load_libraries

setup_trap
ensure_project_root

main() {
    if [[ $# -eq 0 ]]; then
        run_interactive_menu
    else
        dispatch_command "$@"
    fi
}

main "$@"
