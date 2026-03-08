#!/bin/bash

###########
# Build and install OQS-OpenSSH (Open Quantum Safe OpenSSH)
###########

set -eo pipefail

# Source shared configuration (logging.sh is sourced transitively via functions.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/shared/config.sh"
source "${SCRIPT_DIR}/shared/functions.sh"

# Point the centralized logger at the build log file
LOG_FILE="${BUILD_DIR}/oqs_build.log"

install_dependencies() {
    log_info "Installing dependencies (mode: ${BUILD_MODE})..."

    # Skip the ssl-dev package when a suitable OpenSSL (>= 1.1.1) is already
    # present (e.g. built from source). Installing the system package alongside
    # a custom OpenSSL puts an older libcrypto into the standard lib path and
    # causes cmake to pick up the wrong library (C1 fix).
    local need_ssl_dev=true
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libssl 2>/dev/null; then
        log_info "OpenSSL already found via pkg-config — skipping ssl-dev package."
        need_ssl_dev=false
    elif command -v openssl >/dev/null 2>&1; then
        local _ssl_ver
        _ssl_ver="$(openssl version 2>/dev/null | awk '{print $2}')"
        # Accept anything >= 1.1.1 (sort -V: smaller version prints first)
        if [[ "$(printf '1.1.1\n%s' "${_ssl_ver}" | sort -V | head -1)" == "1.1.1" ]]; then
            log_info "OpenSSL ${_ssl_ver} already installed — skipping ssl-dev package."
            need_ssl_dev=false
        fi
    fi

    if [ -f /etc/debian_version ]; then
        # openssh-client provides the system ssh(1) used by copy_key_to_server.sh
        # for the bootstrap key-copy step (before OQS-OpenSSH is built).
        local pkgs="autoconf automake cmake gcc libtool make ninja-build zlib1g-dev git doxygen graphviz openssh-client"
        [[ "$need_ssl_dev" == true ]] && pkgs="${pkgs} libssl-dev"
        # On a server the system sshd must be running on port 22 so clients can
        # use ssh-copy-id for the initial PQ key bootstrap before OQS sshd is set up.
        [[ "${BUILD_MODE}" == "server" ]] && pkgs="${pkgs} openssh-server"
        sudo apt-get update
        # shellcheck disable=SC2086
        sudo apt-get install -y ${pkgs}
        # Start and enable the system sshd so the port-22 bootstrap works immediately.
        # Debian/Ubuntu calls the service 'ssh'; some variants use 'sshd'.
        if [[ "${BUILD_MODE}" == "server" ]]; then
            sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
            sudo systemctl start  ssh 2>/dev/null || sudo systemctl start  sshd 2>/dev/null || true
        fi
    elif [ -f /etc/redhat-release ]; then
        # openssh-clients provides the system ssh(1) on RPM-based distributions.
        local pkgs="autoconf automake cmake gcc libtool make ninja-build zlib-devel git doxygen graphviz pkg-config openssh-clients"
        [[ "$need_ssl_dev" == true ]] && pkgs="${pkgs} openssl-devel"
        [[ "${BUILD_MODE}" == "server" ]] && pkgs="${pkgs} openssh-server"
        # shellcheck disable=SC2086
        sudo dnf install -y ${pkgs}
        if [[ "${BUILD_MODE}" == "server" ]]; then
            sudo systemctl enable --now sshd 2>/dev/null || true
        fi
    else
        log_warn "Unsupported distribution. Please install dependencies manually."
        log_warn "Required: autoconf automake cmake gcc libtool libssl-dev make ninja-build zlib1g-dev git openssh-client"
        [[ "${BUILD_MODE}" == "server" ]] && \
            log_warn "Server mode also requires: openssh-server (start and enable its systemd service)"
    fi

    # Ensure the sshd privilege-separation user and directory exist
    sudo mkdir -p -m 0755 /var/empty
    if ! getent group sshd >/dev/null; then sudo groupadd sshd; fi
    if ! getent passwd sshd >/dev/null; then sudo useradd -g sshd -c 'sshd privsep' -d /var/empty -s /bin/false sshd; fi
}

# _find_openssl_lib LIBNAME
# Locate a shared library (libcrypto or libssl) by checking:
#   1. The runtime linker cache (ldconfig -p) — most reliable
#   2. A OPENSSL_LIB_DIR hint set by the caller
#   3. Common install prefixes and multiarch paths
# Prints the full path on success, empty string on failure.
_find_openssl_lib() {
    local libname="$1"
    local found
    # 1. Runtime linker cache
    found="$(ldconfig -p 2>/dev/null | awk "/\/${libname}\.so[^.0-9]/{print \$NF; exit}")"
    [[ -n "$found" ]] && { echo "$found"; return; }
    # 2. pkg-config lib dir hint
    if [[ -n "${OPENSSL_LIB_DIR:-}" && -f "${OPENSSL_LIB_DIR}/${libname}.so" ]]; then
        echo "${OPENSSL_LIB_DIR}/${libname}.so"; return
    fi
    # 3. Common paths / multiarch dirs
    local _d
    for _d in \
        "${OPENSSL_DETECTED_ROOT:-/usr}/lib" \
        "${OPENSSL_DETECTED_ROOT:-/usr}/lib64" \
        /usr/lib/x86_64-linux-gnu \
        /usr/lib/aarch64-linux-gnu \
        /usr/lib64 \
        /usr/local/lib \
        /usr/local/lib64; do
        [[ -f "${_d}/${libname}.so" ]] && { echo "${_d}/${libname}.so"; return; }
    done
}

# Copy necessary shared libraries
handle_shared_libraries() {
    log_info "Setting up shared libraries..."

    mkdir -p "${INSTALL_PREFIX}/lib"

    if [ -d "${PREFIX}/lib" ]; then
        cp -R "${PREFIX}/lib/"* "${INSTALL_PREFIX}/lib/"
        log_info "Copied liboqs libraries to ${INSTALL_PREFIX}/lib/"
    else
        log_fatal "liboqs libraries not found in ${PREFIX}/lib"
    fi

    # Update ldconfig if on Linux
    if [ "$(uname)" == "Linux" ]; then
        echo "${INSTALL_PREFIX}/lib" | sudo tee /etc/ld.so.conf.d/oqs-ssh.conf
        sudo ldconfig
        log_info "Updated system library cache"
    fi
}

# Main installation process
main() {
    # Accept an optional mode argument: 'server' or 'client' (default: client).
    # Used by install_dependencies to decide whether openssh-server is needed.
    BUILD_MODE="${1:-client}"

    log_section "OQS-OpenSSH Installation"
    log_info "Starting OQS-OpenSSH installation..."

    mkdir -p "${BUILD_DIR}"
    cd "${PROJECT_ROOT}"

    install_dependencies

    # Step 1: Clone liboqs at the tip of the configured branch.
    log_info "Cloning liboqs..."
    rm -rf "${BUILD_DIR}/tmp" && mkdir -p "${BUILD_DIR}/tmp"
    git clone --branch "${LIBOQS_BRANCH}" --single-branch --depth 1 "${LIBOQS_REPO}" "${BUILD_DIR}/tmp/liboqs"

    # ── OpenSSL detection ─────────────────────────────────────────────────────
    # Find the OpenSSL root, then locate libcrypto.so and libssl.so explicitly
    # so that cmake and ./configure both use the same installation even when
    # OpenSSL was built from source or lives in a multiarch directory.
    OPENSSL_LIB_DIR=""
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libssl 2>/dev/null; then
        OPENSSL_DETECTED_ROOT="$(pkg-config --variable=prefix libssl)"
        OPENSSL_LIB_DIR="$(pkg-config --variable=libdir libssl)"
    elif command -v openssl >/dev/null 2>&1; then
        # Derive root from binary path (/usr/local/bin/openssl → /usr/local)
        OPENSSL_DETECTED_ROOT="$(dirname "$(dirname "$(command -v openssl)")")"
    else
        OPENSSL_DETECTED_ROOT="${OPENSSL_SYS_DIR}"
    fi

    # Resolve both library files; cmake's FindOpenSSL requires both (C2 fix).
    OPENSSL_CRYPTO_LIB="$(_find_openssl_lib libcrypto)"
    OPENSSL_SSL_LIB="$(_find_openssl_lib libssl)"

    # Derive lib dir from the found crypto path (used in ldflags below)
    [[ -n "$OPENSSL_CRYPTO_LIB" ]] && OPENSSL_LIB_DIR="$(dirname "$OPENSSL_CRYPTO_LIB")"

    log_info "OpenSSL root:    ${OPENSSL_DETECTED_ROOT}"
    log_info "libcrypto:       ${OPENSSL_CRYPTO_LIB:-<not found — relying on root>}"
    log_info "libssl:          ${OPENSSL_SSL_LIB:-<not found — relying on root>}"
    log_info "OpenSSL lib dir: ${OPENSSL_LIB_DIR:-<unknown>}"
    # Override config default so the openssh ./configure step uses the same root
    OPENSSL_SYS_DIR="${OPENSSL_DETECTED_ROOT}"

    # Step 2: Build liboqs
    log_info "Building liboqs..."
    cd "${BUILD_DIR}/tmp/liboqs"
    rm -rf build
    mkdir build && cd build
    cmake .. -GNinja -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DOPENSSL_ROOT_DIR="${OPENSSL_DETECTED_ROOT}" \
        ${OPENSSL_CRYPTO_LIB:+-DOPENSSL_CRYPTO_LIBRARY="${OPENSSL_CRYPTO_LIB}"} \
        ${OPENSSL_SSL_LIB:+-DOPENSSL_SSL_LIBRARY="${OPENSSL_SSL_LIB}"} \
        -DOQS_ENABLE_SIG_MAYO_2=ON \
        -DOQS_ENABLE_SIG_MAYO_3=ON \
        -DOQS_ENABLE_SIG_MAYO_5=ON
    ninja
    ninja install
    cd "${PROJECT_ROOT}"

    # Step 3: Clone OpenSSH at the tip of the configured branch.
    # Always start from a clean tree so any stale configure.ac patches from a
    # previous failed run don't persist (C4 fix).
    log_info "Cloning OpenSSH..."
    rm -rf "${BUILD_DIR}/openssh"
    # Full clone (no --depth 1): shallow clones of OQS-OpenSSH OQS-v9 intermittently
    # fail with "fatal: unable to read tree <hash>" during the checkout phase because
    # the server's shallow pack omits tree objects that git needs to populate the
    # working directory.  A full clone avoids this without meaningful overhead since
    # the build already downloads ~180 MiB regardless.
    git clone --branch "${OPENSSH_BRANCH}" --single-branch "${OPENSSH_REPO}" "${BUILD_DIR}/openssh"

    # Patch configure.ac to accept OpenSSL 3.5+ (upstream check only tested up to 3.3/3.4).
    # Downgrade the hard error to a warning so the build continues on newer OpenSSL.
    sed -i \
        's/AC_MSG_ERROR(\[Unknown\/unsupported OpenSSL/AC_MSG_WARN([Unknown\/unsupported OpenSSL/' \
        "${BUILD_DIR}/openssh/configure.ac" || true

    # Skip the 'percent' regress test: its revokedhostkeys sub-test compares the
    # %L (local hostname) token against the value returned by hostname(1)/$HOSTNAME,
    # but OpenSSH expands %L via gethostname(2).  On systems where those two
    # sources disagree (e.g. when an OpenVPN chroot leaves a path-like string in
    # /etc/hostname) the expected and actual strings never match.  The mismatch is
    # purely environmental and unrelated to OQS functionality.
    sed -i 's|\(SKIP_LTESTS="[^"]*\)"|\1 percent"|' \
        "${BUILD_DIR}/openssh/oqs-test/run_tests.sh" || true

    # Step 4: Build OpenSSH
    log_info "Building OpenSSH..."
    cd "${BUILD_DIR}/openssh"

    autoreconf -i

    # Build rpath/ldflags: always include the liboqs lib dir; also include the
    # OpenSSL lib dir when it differs (e.g. /usr/local/lib) so the linker finds
    # libssl/libcrypto at both build and run time (H3 fix).
    local _ldflags="-Wl,-rpath -Wl,${INSTALL_PREFIX}/lib"
    if [[ -n "${OPENSSL_LIB_DIR}" && "${OPENSSL_LIB_DIR}" != "${INSTALL_PREFIX}/lib" ]]; then
        _ldflags="${_ldflags} -Wl,-rpath -Wl,${OPENSSL_LIB_DIR} -L${OPENSSL_LIB_DIR}"
    fi

    # Use the real system xauth rather than a non-existent path under INSTALL_PREFIX (L1 fix).
    local _xauth
    _xauth="$(command -v xauth 2>/dev/null || echo /usr/bin/xauth)"

    ./configure --prefix="${INSTALL_PREFIX}" \
               --with-ldflags="${_ldflags}" \
               --with-libs=-lm \
               --with-ssl-dir="${OPENSSL_SYS_DIR}" \
               --with-liboqs-dir="${PREFIX}" \
               --sysconfdir="${INSTALL_PREFIX}/etc" \
               --with-privsep-path="${INSTALL_PREFIX}/var/empty" \
               --with-pid-dir="${INSTALL_PREFIX}/var/run" \
               --with-xauth="${_xauth}" \
               --with-default-path="/usr/local/bin:/usr/bin:/bin" \
               --with-privsep-user=sshd

    make -j"$(nproc)"

    handle_shared_libraries

    make install

    cd "${PROJECT_ROOT}"

    log_section "Installation Complete"
    log_info "OQS-OpenSSH installed to: ${INSTALL_PREFIX}"
    log_info "liboqs installed to:      ${PREFIX}"

    # Optional: Run basic tests — only prompt when stdin is a terminal so that
    # automated callers (e.g. server/update.sh) are not blocked (M4 fix).
    if [[ -t 0 ]]; then
        read -rp "Run tests? (y/N): " run_tests
        if [[ "${run_tests}" == "y" || "${run_tests}" == "Y" ]]; then
            if [ -d "${BUILD_DIR}/openssh" ] && [ -f "${BUILD_DIR}/openssh/oqs-test/run_tests.sh" ]; then
                log_info "Starting test suite..."
                cd "${BUILD_DIR}/openssh" && ./oqs-test/run_tests.sh
            else
                log_error "Test script not found. Cannot run tests."
            fi
        else
            log_info "Skipping tests."
        fi
    else
        log_info "Non-interactive mode — skipping test suite prompt."
    fi
}

main
