#!/bin/bash
# Unit tests for shared/validation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"
source "${SCRIPT_DIR}/../../validation.sh"

# ── validate_ip ───────────────────────────────────────────────────────────────

describe "validate_ip"

it "accepts a valid IPv4 address"
validate_ip "192.168.1.1" 2>/dev/null; assert_zero $?

it "accepts loopback"
validate_ip "127.0.0.1" 2>/dev/null; assert_zero $?

it "accepts a simple hostname"
validate_ip "myserver" 2>/dev/null; assert_zero $?

it "accepts a FQDN"
validate_ip "ssh.example.com" 2>/dev/null; assert_zero $?

it "rejects empty string"
validate_ip "" 2>/dev/null; assert_nonzero $?

it "rejects address with semicolon (injection)"
validate_ip "192.168.1.1;rm -rf /" 2>/dev/null; assert_nonzero $?

it "rejects address with backtick"
validate_ip '`id`' 2>/dev/null; assert_nonzero $?

it "rejects path traversal"
validate_ip "../etc/passwd" 2>/dev/null; assert_nonzero $?

it "rejects IP with out-of-range octet"
validate_ip "256.0.0.1" 2>/dev/null; assert_nonzero $?

it "rejects IP with space"
validate_ip "192.168 .1.1" 2>/dev/null; assert_nonzero $?

# ── validate_port ─────────────────────────────────────────────────────────────

describe "validate_port"

it "accepts port 22"
validate_port "22" 2>/dev/null; assert_zero $?

it "accepts port 1"
validate_port "1" 2>/dev/null; assert_zero $?

it "accepts port 65535"
validate_port "65535" 2>/dev/null; assert_zero $?

it "rejects port 0"
validate_port "0" 2>/dev/null; assert_nonzero $?

it "rejects port 65536"
validate_port "65536" 2>/dev/null; assert_nonzero $?

it "rejects empty string"
validate_port "" 2>/dev/null; assert_nonzero $?

it "rejects non-numeric"
validate_port "abc" 2>/dev/null; assert_nonzero $?

it "rejects negative number"
validate_port "-1" 2>/dev/null; assert_nonzero $?

it "rejects decimal"
validate_port "22.5" 2>/dev/null; assert_nonzero $?

# ── validate_username ─────────────────────────────────────────────────────────

describe "validate_username"

it "accepts lowercase username"
validate_username "alice" 2>/dev/null; assert_zero $?

it "accepts username starting with underscore"
validate_username "_svc" 2>/dev/null; assert_zero $?

it "accepts username with hyphen"
validate_username "ubuntu-user" 2>/dev/null; assert_zero $?

it "accepts username with digits"
validate_username "user01" 2>/dev/null; assert_zero $?

it "rejects empty string"
validate_username "" 2>/dev/null; assert_nonzero $?

it "rejects username starting with a digit"
validate_username "1user" 2>/dev/null; assert_nonzero $?

it "rejects username with space"
validate_username "bad user" 2>/dev/null; assert_nonzero $?

it "rejects username with dollar sign"
validate_username 'user$name' 2>/dev/null; assert_nonzero $?

it "rejects username longer than 32 characters"
validate_username "averylongusernamethatexceedsthirtytwocharacterss" 2>/dev/null; assert_nonzero $?

# ── validate_algorithm_choice ─────────────────────────────────────────────────

describe "validate_algorithm_choice"

it "accepts choice 1 with max 10"
validate_algorithm_choice "1" "10" 2>/dev/null; assert_zero $?

it "accepts choice equal to max"
validate_algorithm_choice "10" "10" 2>/dev/null; assert_zero $?

it "rejects choice 0"
validate_algorithm_choice "0" "10" 2>/dev/null; assert_nonzero $?

it "rejects choice greater than max"
validate_algorithm_choice "11" "10" 2>/dev/null; assert_nonzero $?

it "rejects empty choice"
validate_algorithm_choice "" "10" 2>/dev/null; assert_nonzero $?

it "rejects non-numeric choice"
validate_algorithm_choice "abc" "10" 2>/dev/null; assert_nonzero $?

# ── validate_file_exists ──────────────────────────────────────────────────────

describe "validate_file_exists"

_tmp_file="$(mktemp)"

it "accepts an existing regular file"
validate_file_exists "${_tmp_file}" 2>/dev/null; assert_zero $?

it "rejects a non-existent path"
validate_file_exists "/nonexistent/path/file.txt" 2>/dev/null; assert_nonzero $?

it "rejects empty path"
validate_file_exists "" 2>/dev/null; assert_nonzero $?

it "rejects a directory path"
validate_file_exists "/tmp" 2>/dev/null; assert_nonzero $?

rm -f "${_tmp_file}"

# ── validate_dir_exists ───────────────────────────────────────────────────────

describe "validate_dir_exists"

it "accepts /tmp"
validate_dir_exists "/tmp" 2>/dev/null; assert_zero $?

it "rejects a non-existent directory"
validate_dir_exists "/nonexistent/dir" 2>/dev/null; assert_nonzero $?

it "rejects empty path"
validate_dir_exists "" 2>/dev/null; assert_nonzero $?

it "rejects a file path"
_f="$(mktemp)"
validate_dir_exists "${_f}" 2>/dev/null
assert_nonzero $?
rm -f "${_f}"

# ── validate_writable_path ────────────────────────────────────────────────────

describe "validate_writable_path"

it "accepts a path whose parent dir is writable"
validate_writable_path "/tmp/evaemon_test_writable" 2>/dev/null; assert_zero $?

it "rejects a path whose parent dir does not exist"
validate_writable_path "/nonexistent/dir/file" 2>/dev/null; assert_nonzero $?

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
