#!/bin/bash
set -eo pipefail

# Post-quantum sshd update tool.
#
# Performs a controlled in-place upgrade:
#   1. Optionally pull the latest Evaemon sources (git pull)
#   2. Rebuild liboqs and OQS-OpenSSH (calls build_oqs_openssh.sh)
#   3. Verify the new sshd binary accepts the current config (sshd -t)
#   4. Restart the sshd service (systemctl / direct fallback)
#   5. Confirm the service is healthy after the restart

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

BUILD_SCRIPT="${PROJECT_ROOT}/build_oqs_openssh.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

_service_is_running() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null
    else
        [[ -n "$(_sshd_pid)" ]]
    fi
}

# ── Steps ────────────────────────────────────────────────────────────────────

step_git_pull() {
    log_section "Updating Source Code"

    if [[ ! -d "${PROJECT_ROOT}/.git" ]]; then
        log_warn "Project directory is not a git repository -- skipping git pull."
        return
    fi

    read -rp "Pull latest changes from git? (y/N): " do_pull
    if [[ "${do_pull}" != "y" && "${do_pull}" != "Y" ]]; then
        log_info "Skipping git pull."
        return
    fi

    local branch
    branch="$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    log_info "Current branch: ${branch}"

    local before_hash
    before_hash="$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"

    if git -C "${PROJECT_ROOT}" pull --ff-only origin "${branch}" 2>&1 | \
            while IFS= read -r line; do log_info "  ${line}"; done; then
        local after_hash
        after_hash="$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
        if [[ "$before_hash" == "$after_hash" ]]; then
            log_info "Already up to date."
        else
            log_info "Updated ${before_hash:0:8} -> ${after_hash:0:8}"
        fi
    else
        log_warn "git pull failed or had conflicts. Continuing with existing sources."
    fi
}

step_rebuild() {
    log_section "Rebuilding OQS-OpenSSH"

    validate_file_exists "$BUILD_SCRIPT" || log_fatal "Build script not found: ${BUILD_SCRIPT}"

    log_info "Stopping sshd before rebuild to avoid in-use binary conflicts..."
    if _service_is_running; then
        if command -v systemctl &>/dev/null; then
            log_cmd "Stop sshd service" systemctl stop "${SERVICE_NAME}.service"
        else
            local pid
            pid="$(_sshd_pid)"
            if [[ -n "$pid" ]]; then
                log_cmd "SIGTERM sshd" kill -TERM "$pid"
                sleep 2
            fi
        fi
    fi

    log_info "Running build script..."
    if bash "${BUILD_SCRIPT}"; then
        log_info "Build completed successfully."
    else
        log_fatal "Build failed. Restart sshd manually if the service was stopped."
    fi
}

step_verify_config() {
    log_section "Verifying sshd Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "sshd_config not found at ${CONFIG_FILE} -- skipping config test."
        return
    fi

    if [[ ! -x "${SBIN_DIR}/sshd" ]]; then
        log_warn "sshd binary not found at ${SBIN_DIR}/sshd -- skipping config test."
        return
    fi

    if "${SBIN_DIR}/sshd" -t -f "${CONFIG_FILE}" 2>&1 | \
            while IFS= read -r line; do log_info "  ${line}"; done; then
        log_info "Configuration test passed."
    else
        log_fatal "Configuration test FAILED. Fix ${CONFIG_FILE} before restarting."
    fi
}

step_restart_service() {
    log_section "Restarting sshd Service"

    if command -v systemctl &>/dev/null; then
        log_cmd "Start sshd service" systemctl start "${SERVICE_NAME}.service"
        sleep 2
    else
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_warn "No config file -- skipping automatic restart. Start sshd manually."
            return
        fi
        mkdir -p "$(dirname "$PID_FILE")"
        "${SBIN_DIR}/sshd" -f "${CONFIG_FILE}"
        log_info "sshd started directly."
        sleep 1
    fi
}

step_health_check() {
    log_section "Post-Restart Health Check"

    local attempts=5
    local delay=2
    for (( i=1; i<=attempts; i++ )); do
        if _service_is_running; then
            log_info "sshd is running after restart."
            if command -v systemctl &>/dev/null; then
                systemctl status "${SERVICE_NAME}.service" --no-pager -l 2>/dev/null | \
                    tail -n 10 | while IFS= read -r line; do log_info "  ${line}"; done
            else
                local pid
                pid="$(_sshd_pid)"
                log_info "  PID: ${pid}"
            fi
            return
        fi
        log_warn "  Attempt ${i}/${attempts}: sshd not yet up, waiting ${delay}s..."
        sleep "$delay"
    done

    log_fatal "sshd did not come up after restart. Check: journalctl -u ${SERVICE_NAME} -xe"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_section "Post-Quantum sshd Update"
    log_warn "This will rebuild OQS-OpenSSH and briefly restart sshd."
    log_warn "Existing SSH sessions will NOT be interrupted by a graceful restart,"
    log_warn "but new connections will be unavailable for a few seconds."
    echo
    read -rp "Continue with update? (y/N): " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        log_info "Update cancelled."
        exit 0
    fi

    step_git_pull
    step_rebuild
    step_verify_config
    step_restart_service
    step_health_check

    log_section "Update Complete"
    log_info "OQS-OpenSSH has been rebuilt and sshd is running."
    log_info "Verify clients can still connect before closing this session."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
