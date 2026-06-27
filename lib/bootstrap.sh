#!/usr/bin/env bash
# Bootstrap: load all library modules.

load_libraries() {
    # shellcheck source=lib/utils.sh
    source "${PROJECT_ROOT}/lib/utils.sh"
    # shellcheck source=lib/validation.sh
    source "${PROJECT_ROOT}/lib/validation.sh"
    # shellcheck source=lib/ui.sh
    source "${PROJECT_ROOT}/lib/ui.sh"
    # shellcheck source=lib/docker.sh
    source "${PROJECT_ROOT}/lib/docker.sh"
    # shellcheck source=lib/generator.sh
    source "${PROJECT_ROOT}/lib/generator.sh"
    # shellcheck source=lib/credentials.sh
    source "${PROJECT_ROOT}/lib/credentials.sh"
    # shellcheck source=lib/network.sh
    source "${PROJECT_ROOT}/lib/network.sh"
    # shellcheck source=lib/installer.sh
    source "${PROJECT_ROOT}/lib/installer.sh"
    # shellcheck source=lib/install.sh
    source "${PROJECT_ROOT}/lib/install.sh"
    # shellcheck source=lib/uninstall.sh
    source "${PROJECT_ROOT}/lib/uninstall.sh"
    # shellcheck source=lib/commands.sh
    source "${PROJECT_ROOT}/lib/commands.sh"
    # shellcheck source=lib/diagnostics.sh
    source "${PROJECT_ROOT}/lib/diagnostics.sh"
    # shellcheck source=lib/menu.sh
    source "${PROJECT_ROOT}/lib/menu.sh"
}
