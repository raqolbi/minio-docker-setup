#!/usr/bin/env bash
# Silo release check and optional scheduled auto-update (systemd timer).

SILO_IMAGE_REPO="docker.io/pgsty/silo"
SILO_RELEASES_API="https://api.github.com/repos/pgsty/silo/releases?per_page=10"

# Stable (non-draft, non-prerelease) Silo release tags, newest first.
silo_stable_release_tags() {
    local json

    json=$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
        "${SILO_RELEASES_API}" 2>/dev/null) || return 1

    if command_exists python3; then
        printf '%s' "${json}" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if not r.get("draft") and not r.get("prerelease"):
        print(r.get("tag_name", ""))
' 2>/dev/null
    else
        printf '%s' "${json}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]*)"$/\1/'
    fi | grep -E '^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$' | sort -r
}

# A GitHub release can appear before its multi-arch image is pushed.
image_published() {
    docker manifest inspect "$1" &>/dev/null
}

# Sets LATEST_SILO_IMAGE to the newest release whose image is published.
# Returns 1 if GitHub/Docker Hub cannot be reached or nothing is published.
silo_latest_published_image() {
    local tags tag checked=0

    LATEST_SILO_IMAGE=""
    tags=$(silo_stable_release_tags) || return 1
    [[ -n "${tags}" ]] || return 1

    while IFS= read -r tag; do
        [[ -n "${tag}" ]] || continue
        if image_published "${SILO_IMAGE_REPO}:${tag}"; then
            LATEST_SILO_IMAGE="${SILO_IMAGE_REPO}:${tag}"
            return 0
        fi
        log_info "Release ${tag} has no published image yet; trying the previous release." >&2
        checked=$((checked + 1))
        [[ "${checked}" -ge 5 ]] && break
    done <<< "${tags}"

    return 1
}

# Current Silo tag, or empty if the install does not run a Silo image.
current_silo_tag() {
    local image="${MINIO_IMAGE:-}"

    if [[ "${image}" == *"pgsty/silo:"* ]]; then
        printf '%s' "${image##*:}"
    fi
}

# Sets LATEST_SILO_IMAGE; returns 0 when it is newer than the running image
# (or the install does not run Silo yet), 1 when up to date, 2 on lookup error.
check_silo_update() {
    local latest current

    silo_latest_published_image || return 2
    latest="${LATEST_SILO_IMAGE##*:}"
    current=$(current_silo_tag)

    # RELEASE.YYYY-MM-DDTHH-MM-SSZ sorts chronologically as a string.
    if [[ -z "${current}" || "${latest}" > "${current}" ]]; then
        return 0
    fi

    return 1
}

# Image for a fresh install or 'update': newest published Silo release.
resolve_target_image() {
    if silo_latest_published_image; then
        printf '%s' "${LATEST_SILO_IMAGE}"
        return 0
    fi

    log_error "Could not determine the latest Silo release." >&2
    log_error "The server needs outbound HTTPS to api.github.com and Docker Hub." >&2
    return 1
}

notify_webhook() {
    local message="$1"
    local url="${AUTO_UPDATE_WEBHOOK:-}"
    local escaped

    [[ -n "${url}" ]] || return 0

    escaped=${message//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    # 'text' = Slack/Mattermost/Google Chat, 'content' = Discord.
    curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' \
        -d "{\"text\":\"${escaped}\",\"content\":\"${escaped}\"}" "${url}" &>/dev/null \
        || log_warn "Webhook notification failed."
}

update_marker_file() {
    echo "${PROJECT_ROOT}/.update-available"
}

cmd_check_update() {
    local rc=0 marker

    load_env_file
    marker="$(update_marker_file)"

    log_step "Checking latest Silo release..."
    check_silo_update || rc=$?

    case "${rc}" in
        0)
            log_warn "Update available: ${MINIO_IMAGE} -> ${LATEST_SILO_IMAGE}"
            log_info "Release notes: https://github.com/pgsty/silo/releases/tag/${LATEST_SILO_IMAGE##*:}"
            log_info "Apply with: ./setup.sh update"
            printf '%s\n' "${LATEST_SILO_IMAGE}" > "${marker}"
            return 0
            ;;
        1)
            log_success "Up to date (${MINIO_IMAGE})."
            rm -f "${marker}"
            return 1
            ;;
        *)
            log_error "Could not query Silo releases (api.github.com / Docker Hub unreachable?)."
            return 2
            ;;
    esac
}

prune_old_backups() {
    local keep="${1:-3}"
    local dir="${PROJECT_ROOT}/backups"
    local -a archives=()
    local i

    [[ -d "${dir}" ]] || return 0
    mapfile -t archives < <(find "${dir}" -maxdepth 1 -type f -name 'backup-*.tar.gz' | sort -r)

    for ((i = keep; i < ${#archives[@]}; i++)); do
        log_info "Removing old backup ${archives[$i]}"
        rm -f "${archives[$i]}"
    done
}

# Entry point for the systemd timer.
auto_update_run() {
    local mode rc=0 old_image host

    load_env_file
    acquire_operation_lock
    mode="${AUTO_UPDATE_MODE:-check}"
    host="$(hostname 2>/dev/null || echo server)"
    old_image="${MINIO_IMAGE}"

    cmd_check_update || rc=$?

    if [[ "${rc}" -ne 0 ]]; then
        [[ "${rc}" -eq 2 ]] && notify_webhook "[${host}] MinIO/Silo update check failed (GitHub unreachable)."
        return 0
    fi

    if [[ "${mode}" != "apply" ]]; then
        notify_webhook "[${host}] Silo update available for ${MINIO_CONTAINER_NAME}: ${old_image} -> ${LATEST_SILO_IMAGE}. Run ./setup.sh update"
        return 0
    fi

    # Do not start a server the admin stopped on purpose.
    if ! container_is_running; then
        log_warn "Container ${MINIO_CONTAINER_NAME} is not running; skipping automatic apply."
        notify_webhook "[${host}] Silo update available for ${MINIO_CONTAINER_NAME} (${LATEST_SILO_IMAGE}), not applied because the container is stopped."
        restore_project_ownership
        return 0
    fi

    log_progress "Auto-applying update to ${LATEST_SILO_IMAGE}..."
    # shellcheck disable=SC2034  # read by confirm/prompt_yes_no in utils.sh
    ASSUME_YES=true
    # Subshell: a 'die' inside the update must not skip the failure notification.
    # (Not in an if/|| context, so 'set -e' stays active inside.)
    set +e
    ( install_err_trap; set -e; cmd_update "${LATEST_SILO_IMAGE}" )
    rc=$?
    set -e
    restore_project_ownership

    if [[ "${rc}" -eq 0 ]]; then
        rm -f "$(update_marker_file)"
        prune_old_backups "${AUTO_UPDATE_KEEP_BACKUPS:-3}"
        notify_webhook "[${host}] ${MINIO_CONTAINER_NAME} updated: ${old_image} -> ${LATEST_SILO_IMAGE}"
    else
        load_env_file
        notify_webhook "[${host}] ${MINIO_CONTAINER_NAME} update to ${LATEST_SILO_IMAGE} FAILED; now running ${MINIO_IMAGE}. Check ./setup.sh logs"
        return 1
    fi
}

auto_update_unit_name() {
    local name="${MINIO_CONTAINER_NAME:-minio}"
    echo "minio-setup-update-${name//[^a-zA-Z0-9_-]/_}"
}

auto_update_enable() {
    local unit schedule mode webhook
    local service_file timer_file

    load_env_file
    command_exists systemctl || die "systemd is required for scheduled updates."
    unit="$(auto_update_unit_name)"

    echo ""
    echo "Auto-update mode:"
    echo "  1) check  — only detect new releases (status/diagnose + optional webhook)  [recommended]"
    echo "  2) apply  — automatically back up, upgrade, and roll back on failure (brief downtime)"
    read -r -p "Select option [1]: " mode
    case "${mode:-1}" in
        1) mode="check" ;;
        2) mode="apply" ;;
        *) die "Invalid option." ;;
    esac

    log_info "Schedule uses systemd OnCalendar syntax, e.g. 'Sun *-*-* 03:30:00' (weekly) or 'daily'."
    while true; do
        schedule=$(prompt_default "Schedule" "${AUTO_UPDATE_SCHEDULE:-Sun *-*-* 03:30:00}")
        if [[ "${schedule}" == *$'\n'* || -z "${schedule}" ]]; then
            log_error "Invalid schedule."
            continue
        fi
        if ! command_exists systemd-analyze || systemd-analyze calendar "${schedule}" &>/dev/null; then
            break
        fi
        log_error "Invalid OnCalendar expression: ${schedule}"
    done

    local webhook_hint="none"
    [[ -n "${AUTO_UPDATE_WEBHOOK:-}" ]] && webhook_hint="keep current"
    while true; do
        read -r -p "Webhook URL for notifications (Slack/Discord/Mattermost; '-' = none) [${webhook_hint}]: " webhook
        case "${webhook}" in
            "") webhook="${AUTO_UPDATE_WEBHOOK:-}"; break ;;
            -) webhook=""; break ;;
            https://*|http://*)
                [[ "${webhook}" =~ ^https?://[^[:space:]\'\"]+$ ]] && break
                log_error "Webhook URL contains invalid characters." ;;
            *) log_error "Webhook URL must start with http:// or https://" ;;
        esac
    done

    set_env_key_in_file "AUTO_UPDATE_MODE" "${mode}"
    set_env_key_in_file "AUTO_UPDATE_SCHEDULE" "${schedule}"
    set_env_key_in_file "AUTO_UPDATE_WEBHOOK" "${webhook}"

    service_file="/etc/systemd/system/${unit}.service"
    timer_file="/etc/systemd/system/${unit}.timer"

    # The timer runs setup.sh as root. If anyone but the owner can modify the
    # scripts, that is a root privilege escalation.
    local writable="" path mode owner group
    for path in "${PROJECT_ROOT}" "${PROJECT_ROOT}/setup.sh" "${PROJECT_ROOT}/lib" "${PROJECT_ROOT}"/lib/*.sh; do
        read -r mode owner group < <(stat -c '%a %U %G' "${path}")
        # World-writable is always unsafe; group-writable is fine only for the
        # owner's private group (Ubuntu's default umask 002).
        if (( 8#${mode} & 8#002 )) || { (( 8#${mode} & 8#020 )) && [[ "${group}" != "${owner}" ]]; }; then
            writable+="${path} (${mode} ${owner}:${group})"$'\n'
        fi
    done
    if [[ -n "${writable}" ]]; then
        log_error "These paths are group/world-writable and would run as root via the timer:"
        printf '%s' "${writable}" | sed 's/^/  /'
        die "Fix with: chmod -R go-w ${PROJECT_ROOT}"
    fi

    # systemd treats '%' as a specifier; quote the paths for spaces.
    local esc_root="${PROJECT_ROOT//%/%%}"

    log_step "Installing ${service_file} and ${timer_file}..."
    run_as_root tee "${service_file}" >/dev/null <<UNIT
[Unit]
Description=MinIO (Silo) update ${mode} for ${MINIO_CONTAINER_NAME}
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=${esc_root}
ExecStart=/bin/bash "${esc_root}/setup.sh" auto-update run
StandardInput=null
UNIT

    run_as_root tee "${timer_file}" >/dev/null <<UNIT
[Unit]
Description=Scheduled MinIO (Silo) update ${mode} for ${MINIO_CONTAINER_NAME}

[Timer]
OnCalendar=${schedule}
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable --now "${unit}.timer"

    log_success "Auto-update enabled (mode: ${mode}, schedule: ${schedule})."
    if [[ "${mode}" == "apply" ]]; then
        log_warn "Apply mode recreates the container (brief downtime) and stops MinIO during the backup."
        log_info "Keeps the last ${AUTO_UPDATE_KEEP_BACKUPS:-3} backups. Set AUTO_UPDATE_KEEP_BACKUPS in .env to change."
    fi
    log_info "Logs: journalctl -u ${unit}.service"
}

auto_update_disable() {
    local unit

    load_env_file
    unit="$(auto_update_unit_name)"

    run_as_root systemctl disable --now "${unit}.timer" 2>/dev/null || true
    run_as_root rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"
    run_as_root systemctl daemon-reload
    set_env_key_in_file "AUTO_UPDATE_MODE" ""

    log_success "Auto-update disabled."
}

auto_update_status() {
    local unit marker

    load_env_file
    unit="$(auto_update_unit_name)"
    marker="$(update_marker_file)"

    echo ""
    echo -e "${BOLD}Auto-update${NC}"
    echo "  Current image: ${MINIO_IMAGE}"
    if [[ -n "${AUTO_UPDATE_MODE:-}" ]]; then
        echo "  Mode:          ${AUTO_UPDATE_MODE}"
        echo "  Schedule:      ${AUTO_UPDATE_SCHEDULE:-?}"
        echo "  Webhook:       $([[ -n "${AUTO_UPDATE_WEBHOOK:-}" ]] && echo configured || echo none)"
        systemctl list-timers "${unit}.timer" --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
    else
        echo "  Status:        disabled (enable with: ./setup.sh auto-update enable)"
    fi
    if [[ -f "${marker}" ]]; then
        echo -e "  ${YELLOW}Update available: $(<"${marker}")${NC}"
    fi
    echo ""
}

cmd_auto_update() {
    case "${1:-status}" in
        enable)  auto_update_enable ;;
        disable) auto_update_disable ;;
        status)  auto_update_status ;;
        run)     auto_update_run ;;
        *) die "Usage: ./setup.sh auto-update [enable|disable|status|run]" ;;
    esac
}
