#!/bin/bash
set -eo pipefail

# Resolve the project root from the wizard's own location so the script works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="1.0.0"
BUILD_LOG="${SCRIPT_DIR}/build/oqs_build.log"

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "This wizard must be run as root (sudo)."
    exit 1
fi

# Check whiptail availability
if ! command -v whiptail &>/dev/null; then
    echo "whiptail is required but not installed."
    echo "Install it with: apt install whiptail"
    exit 1
fi

# ── Branding ──────────────────────────────────────────────────────────────────
# Dark theme with cyan accents — "Evaemon: The last infrastructure."
export NEWT_COLORS='
root=brightcyan,black
border=cyan,black
window=white,black
shadow=black,black
title=brightwhite,black
button=black,cyan
actbutton=black,brightcyan
checkbox=cyan,black
actcheckbox=black,cyan
entry=brightwhite,black
label=cyan,black
listbox=brightwhite,black
actlistbox=black,cyan
textbox=brightwhite,black
acttextbox=brightwhite,blue
helpline=black,cyan
roottext=brightcyan,black
'

# ── Terminal dimensions ───────────────────────────────────────────────────────
# Enforce minimum sizes so menus are never clipped on small terminals.
TERM_H=$(tput lines 2>/dev/null || echo 24)
TERM_W=$(tput cols  2>/dev/null || echo 80)
BOX_H=$(( TERM_H > 24 ? TERM_H - 4 : 20 ))
BOX_W=$(( TERM_W > 60 ? TERM_W - 10 : 60 ))

# ── Splash screen ─────────────────────────────────────────────────────────────
# Shown once at startup in the terminal (before the first whiptail dialog).
# Uses ANSI cyan on black to match the NEWT_COLORS theme.
show_splash() {
    clear
    # Cyan
    printf '\033[0;36m'
    cat << 'LOGO'

  ███████╗ ██╗   ██╗  █████╗  ███████╗ ███╗   ███╗  ██████╗  ███╗  ██╗
  ██╔════╝ ╚██╗ ██╔╝ ██╔══██╗ ██╔════╝ ████╗ ████║ ██╔═══██╗ ████╗ ██║
  █████╗    ╚████╔╝  ███████║ █████╗   ██╔████╔██║ ██║   ██║ ██╔██╗██║
  ██╔══╝    ╔███╔╝   ██╔══██║ ██╔══╝   ██║╚██╔╝██║ ██║   ██║ ██║╚████║
  ███████╗   ██║     ██║  ██║ ███████╗ ██║ ╚═╝ ██║ ╚██████╔╝ ██║ ╚███║
  ╚══════╝   ╚═╝     ╚═╝  ╚═╝ ╚══════╝ ╚═╝     ╚═╝  ╚═════╝  ╚═╝  ╚══╝

LOGO
    # Dim white for tagline
    printf '\033[0;37m'
    printf '  %s\n\n' '──  The last infrastructure.  ──'
    printf '\033[0m'
    sleep 1.5
}

# ── Helpers ───────────────────────────────────────────────────────────────────

ensure_permissions() {
    local scripts=(
        "${SCRIPT_DIR}/build_oqs_openssh.sh"
        "${SCRIPT_DIR}/server/server.sh"
        "${SCRIPT_DIR}/server/monitoring.sh"
        "${SCRIPT_DIR}/server/update.sh"
        "${SCRIPT_DIR}/server/pq_only_testmode.sh"
        "${SCRIPT_DIR}/server/tools/diagnostics.sh"
        "${SCRIPT_DIR}/client/keygen.sh"
        "${SCRIPT_DIR}/client/copy_key_to_server.sh"
        "${SCRIPT_DIR}/client/connect.sh"
        "${SCRIPT_DIR}/client/backup.sh"
        "${SCRIPT_DIR}/client/health_check.sh"
        "${SCRIPT_DIR}/client/key_rotation.sh"
        "${SCRIPT_DIR}/client/migrate_keys.sh"
        "${SCRIPT_DIR}/client/tools/debug.sh"
        "${SCRIPT_DIR}/client/tools/performance_test.sh"
    )
    for script in "${scripts[@]}"; do
        [ -f "$script" ] && chmod +x "$script"
    done
}

oqs_is_built() {
    [ -x "${SCRIPT_DIR}/build/bin/ssh" ]
}

_oqs_status_label() {
    if oqs_is_built; then echo "INSTALLED"; else echo "NOT BUILT"; fi
}

# ── Build (runs in background with a step-aware gauge) ────────────────────────
#
# whiptail --gauge supports the dialog XXX protocol: sending
#   XXX\n<pct>\n<new description>\nXXX\n
# updates both the progress bar AND the description text in real time.
# This lets us show "Step N/7 — <what is happening>" as the build progresses.

_build_gauge() {
    local pid="$1"
    local pct=0
    local msg="  Preparing build environment..."

    # Emit an initial state so the gauge is not empty at startup.
    printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$msg"

    while kill -0 "$pid" 2>/dev/null; do
        if   grep -q "Installation Complete"   "${BUILD_LOG}" 2>/dev/null; then
            pct=98; msg="  Step 7/7  —  Finalizing installation"
        elif grep -q "Setting up shared"       "${BUILD_LOG}" 2>/dev/null; then
            pct=85; msg="  Step 6/7  —  Linking shared libraries"
        elif grep -q "Building OpenSSH"        "${BUILD_LOG}" 2>/dev/null; then
            pct=55; msg="  Step 5/7  —  Compiling OpenSSH"
        elif grep -q "Cloning OpenSSH"         "${BUILD_LOG}" 2>/dev/null; then
            pct=42; msg="  Step 4/7  —  Cloning OpenSSH"
        elif grep -q "Building liboqs"         "${BUILD_LOG}" 2>/dev/null; then
            pct=18; msg="  Step 3/7  —  Building liboqs"
        elif grep -q "Cloning liboqs"          "${BUILD_LOG}" 2>/dev/null; then
            pct=8;  msg="  Step 2/7  —  Cloning liboqs"
        elif grep -q "Installing dependencies" "${BUILD_LOG}" 2>/dev/null; then
            pct=3;  msg="  Step 1/7  —  Installing dependencies"
        fi
        printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$msg"
        sleep 1
    done

    # Signal completion.
    printf 'XXX\n100\n  Step 7/7  —  Installation complete!\nXXX\n'
    sleep 0.4
}

handle_build() {
    local mode="${1:-client}"

    if oqs_is_built; then
        if ! whiptail --title "Evaemon v${VERSION}" \
                --yesno "OQS-OpenSSH is already built.\n\nRebuild from scratch?" 9 52; then
            return 0
        fi
    fi

    mkdir -p "${SCRIPT_DIR}/build"

    # Launch build in background; stdin closed so the test-suite prompt is
    # automatically skipped (build_oqs_openssh.sh detects non-interactive stdin).
    bash "${SCRIPT_DIR}/build_oqs_openssh.sh" "${mode}" </dev/null &
    local build_pid=$!

    # Stream step descriptions + percentages to the gauge.
    _build_gauge "$build_pid" | \
        whiptail \
            --title "Evaemon — Compiling OQS Stack" \
            --gauge "  Initializing..." \
            9 62 0 2>/dev/null || true

    # Reap the background process and capture its exit code.
    local exit_code=0
    wait "$build_pid" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        whiptail --title "Build Complete" \
            --msgbox \
"  OQS-OpenSSH installed successfully!

  You can now configure your server or generate
  post-quantum SSH keys." \
            10 52
    else
        if whiptail --title "Build Failed" \
                --yesno \
"  Build FAILED (exit code: ${exit_code}).

  View the build log?" \
                9 50; then
            if [[ -f "${BUILD_LOG}" ]]; then
                whiptail --title "Build Log" --scrolltext \
                    --textbox "${BUILD_LOG}" "$BOX_H" "$BOX_W"
            else
                whiptail --title "Build Log" \
                    --msgbox "  Log file not found:\n  ${BUILD_LOG}" 8 60
            fi
        fi
    fi
}

# ── Sub-script runner ─────────────────────────────────────────────────────────
# Interactive sub-scripts run in full terminal mode (they use read -rp).
# After they finish, a whiptail result box brings the user back into the TUI.

run_sub() {
    local title="$1"
    local script="$2"
    shift 2
    clear
    echo "=== ${title} ==="
    echo
    local exit_code=0
    bash "$script" "$@" || exit_code=$?
    echo
    if [[ $exit_code -eq 0 ]]; then
        whiptail --title "${title}" \
            --msgbox "  Completed successfully.\n\n  Press OK to return to the menu." \
            8 50 2>/dev/null \
            || { echo "Done. Press Enter to return..."; read -r; }
    else
        whiptail --title "${title}" \
            --msgbox \
"  An error occurred (exit code: ${exit_code}).

  Scroll up to review the output,
  then press OK to return to the menu." \
            10 54 2>/dev/null \
            || { echo "Error. Press Enter to return..."; read -r; }
    fi
}

# ── Menus ─────────────────────────────────────────────────────────────────────

handle_server_menu() {
    while true; do
        local build_label
        if oqs_is_built; then
            build_label="Build / Rebuild OQS-OpenSSH  [INSTALLED]"
        else
            build_label="Build OQS-OpenSSH             [NOT BUILT - START HERE]"
        fi

        local choice
        choice=$(whiptail --title "Evaemon v${VERSION} — Server" \
            --menu "Server Configuration:" "$BOX_H" "$BOX_W" 8 \
            "1" "${build_label}" \
            "2" "Configure sshd" \
            "3" "Monitor sshd" \
            "4" "Update / Rebuild" \
            "5" "PQ-Only Test Mode (experimental)" \
            "6" "Diagnostics" \
            "7" "Back to Main Menu" \
            "8" "Exit" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            1) handle_build server ;;
            2) run_sub "Server Configuration" "${SCRIPT_DIR}/server/server.sh" ;;
            3) run_sub "sshd Monitor"         "${SCRIPT_DIR}/server/monitoring.sh" ;;
            4) run_sub "Update / Rebuild"     "${SCRIPT_DIR}/server/update.sh" ;;
            5) run_sub "PQ-Only Test Mode"    "${SCRIPT_DIR}/server/pq_only_testmode.sh" ;;
            6) run_sub "Diagnostics"          "${SCRIPT_DIR}/server/tools/diagnostics.sh" ;;
            7) return 0 ;;
            8) exit 0 ;;
        esac
    done
}

handle_client_menu() {
    while true; do
        local build_label
        if oqs_is_built; then
            build_label="Build / Rebuild OQS-OpenSSH  [INSTALLED]"
        else
            build_label="Build OQS-OpenSSH             [NOT BUILT - START HERE]"
        fi

        local choice
        choice=$(whiptail --title "Evaemon v${VERSION} — Client" \
            --menu "Client Configuration:" "$BOX_H" "$BOX_W" 12 \
            "1"  "${build_label}" \
            "2"  "Generate Keys" \
            "3"  "Copy Key to Server" \
            "4"  "Connect to Server" \
            "5"  "Backup / Restore Keys" \
            "6"  "Health Check" \
            "7"  "Rotate Keys" \
            "8"  "Migrate Classical Keys to PQ" \
            "9"  "Debug Tools" \
            "10" "Performance Benchmark" \
            "11" "Back to Main Menu" \
            "12" "Exit" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            1)  handle_build client ;;
            2)  run_sub "Key Generation"        "${SCRIPT_DIR}/client/keygen.sh" ;;
            3)  run_sub "Copy Key to Server"    "${SCRIPT_DIR}/client/copy_key_to_server.sh" ;;
            4)  run_sub "SSH Connection"        "${SCRIPT_DIR}/client/connect.sh" ;;
            5)  run_sub "Backup / Restore"      "${SCRIPT_DIR}/client/backup.sh" ;;
            6)  run_sub "Health Check"          "${SCRIPT_DIR}/client/health_check.sh" ;;
            7)  run_sub "Key Rotation"          "${SCRIPT_DIR}/client/key_rotation.sh" ;;
            8)  run_sub "Key Migration"         "${SCRIPT_DIR}/client/migrate_keys.sh" ;;
            9)  run_sub "Debug Tools"           "${SCRIPT_DIR}/client/tools/debug.sh" ;;
            10) run_sub "Performance Benchmark" "${SCRIPT_DIR}/client/tools/performance_test.sh" ;;
            11) return 0 ;;
            12) exit 0 ;;
        esac
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    ensure_permissions
    show_splash

    while true; do
        local oqs_status menu_text
        oqs_status="$(_oqs_status_label)"
        if oqs_is_built; then
            menu_text="  OQS-OpenSSH: ${oqs_status}\n\n  Select the role of this machine:"
        else
            menu_text="  OQS-OpenSSH: ${oqs_status}\n  Run Build first after selecting a role.\n\n  Select the role of this machine:"
        fi

        local choice
        choice=$(whiptail --title "Evaemon v${VERSION}" \
            --menu "${menu_text}" "$BOX_H" "$BOX_W" 3 \
            "1" "Server" \
            "2" "Client" \
            "3" "Exit" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) handle_server_menu ;;
            2) handle_client_menu ;;
            3) exit 0 ;;
        esac
    done
}

main
