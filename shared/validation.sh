#!/bin/bash

# Input validation library for Evaemon
# All functions print an error message (via log_error if available, else stderr)
# and return 1 on failure, 0 on success.
#
# Usage:
#   source shared/logging.sh   # optional but recommended
#   source shared/validation.sh
#
#   validate_ip   "$server_host" || exit 1
#   validate_port "$server_port" || exit 1

# ── Internal helper ──────────────────────────────────────────────────────────

_val_error() {
    if declare -f log_error &>/dev/null; then
        log_error "$*"
    else
        echo "ERROR: $*" >&2
    fi
}

# ── Network ──────────────────────────────────────────────────────────────────

# validate_ip VALUE
# Accepts IPv4 dotted-decimal addresses and simple hostnames/FQDNs.
# Rejects empty strings, shell metacharacters, and addresses with path traversal.
validate_ip() {
    local value="$1"

    if [[ -z "$value" ]]; then
        _val_error "Host/IP address must not be empty."
        return 1
    fi

    # Reject anything that could be used for shell injection
    if [[ "$value" =~ [[:space:]\;\&\|\`\$\(\)\<\>\'\"] ]]; then
        _val_error "Host/IP '${value}' contains illegal characters."
        return 1
    fi

    # Reject path traversal
    if [[ "$value" == *".."* || "$value" == *"/"* ]]; then
        _val_error "Host/IP '${value}' contains illegal path characters."
        return 1
    fi

    # Must be a valid IPv4 or a hostname (letters, digits, hyphens, dots)
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Extra check: each octet must be 0-255
        local IFS='.'
        read -ra octets <<< "$value"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                _val_error "IP address '${value}' has an invalid octet: ${octet}."
                return 1
            fi
        done
    elif [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        : # valid hostname / FQDN
    else
        _val_error "Host/IP '${value}' is not a valid IPv4 address or hostname."
        return 1
    fi

    return 0
}

# validate_port VALUE
# Accepts integers in the range 1–65535.
validate_port() {
    local value="$1"

    if [[ -z "$value" ]]; then
        _val_error "Port number must not be empty."
        return 1
    fi

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        _val_error "Port '${value}' is not a valid integer."
        return 1
    fi

    if (( value < 1 || value > 65535 )); then
        _val_error "Port '${value}' is out of the valid range (1–65535)."
        return 1
    fi

    return 0
}

# ── User / system identifiers ────────────────────────────────────────────────

# validate_username VALUE
# Accepts POSIX-compliant usernames: start with a letter or underscore,
# followed by letters, digits, underscores, or hyphens; max 32 chars.
validate_username() {
    local value="$1"

    if [[ -z "$value" ]]; then
        _val_error "Username must not be empty."
        return 1
    fi

    if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]]; then
        _val_error "Username '${value}' is not a valid POSIX username."
        return 1
    fi

    return 0
}

# ── Algorithm selection ──────────────────────────────────────────────────────

# validate_algorithm_choice VALUE MAX
# VALUE must be an integer in the range [1, MAX].
validate_algorithm_choice() {
    local value="$1"
    local max="$2"

    if [[ -z "$value" ]]; then
        _val_error "Algorithm selection must not be empty."
        return 1
    fi

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        _val_error "Algorithm selection '${value}' is not a valid number."
        return 1
    fi

    if (( value < 1 || value > max )); then
        _val_error "Algorithm selection '${value}' is out of range (1–${max})."
        return 1
    fi

    return 0
}

# ── File paths ───────────────────────────────────────────────────────────────

# validate_file_exists PATH
# Checks that a file exists and is a regular file.
validate_file_exists() {
    local path="$1"

    if [[ -z "$path" ]]; then
        _val_error "File path must not be empty."
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        _val_error "File not found: '${path}'."
        return 1
    fi

    return 0
}

# validate_dir_exists PATH
# Checks that a directory exists.
validate_dir_exists() {
    local path="$1"

    if [[ -z "$path" ]]; then
        _val_error "Directory path must not be empty."
        return 1
    fi

    if [[ ! -d "$path" ]]; then
        _val_error "Directory not found: '${path}'."
        return 1
    fi

    return 0
}

# validate_writable_path PATH
# Checks that a path's parent directory exists and is writable.
validate_writable_path() {
    local path="$1"
    local dir
    dir="$(dirname "$path")"

    validate_dir_exists "$dir" || return 1

    if [[ ! -w "$dir" ]]; then
        _val_error "Directory '${dir}' is not writable."
        return 1
    fi

    return 0
}
