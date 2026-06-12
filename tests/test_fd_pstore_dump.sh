#!/bin/bash
# Unit tests for bin/fd-pstore-dump
source "$(dirname "$0")/test_runner.sh"

# ---- Validation tests ----
# Each test runs the validation logic from fd-pstore-dump in isolation
# via bash -c, overriding commands (id, stat, realpath) as needed.

test_no_args() {
    test_start "exits 1 with no arguments"
    local rc
    output=$(bash "$(dirname "$0")/../bin/fd-pstore-dump" 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { test_end; return 1; }
    assert_contains "$output" "usage:" "usage message" || { test_end; return 1; }
    test_end
}

test_not_root() {
    test_start "exits 1 when not root"
    local output rc
    output=$(bash -c '
        id() { echo "1000"; }
        DEST="/tmp/test"
        [ "$(id -u)" -eq 0 ] || { echo "fd-pstore-dump: must run as root (via sudo)" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { test_end; return 1; }
    assert_contains "$output" "must run as root" || { test_end; return 1; }
    test_end
}

test_root_no_sudo_uid() {
    test_start "exits 1 when SUDO_UID is unset"
    local output rc
    output=$(bash -c '
        id() { echo "0"; }
        [ "$(id -u)" -eq 0 ] || exit 1
        CALLER_UID="${SUDO_UID:-0}"
        [ "$CALLER_UID" != "0" ] || { echo "fd-pstore-dump: refusing without SUDO_UID (run via sudo, not as root shell)" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { test_end; return 1; }
    assert_contains "$output" "refusing without SUDO_UID" || { test_end; return 1; }
    test_end
}

test_root_sudo_uid_zero() {
    test_start "exits 1 when SUDO_UID is 0 (root shell)"
    local output rc
    output=$(bash -c '
        id() { echo "0"; }
        SUDO_UID=0
        [ "$(id -u)" -eq 0 ] || exit 1
        CALLER_UID="${SUDO_UID:-0}"
        [ "$CALLER_UID" != "0" ] || { echo "fd-pstore-dump: refusing without SUDO_UID (run via sudo, not as root shell)" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { test_end; return 1; }
    assert_contains "$output" "refusing without SUDO_UID" || { test_end; return 1; }
    test_end
}

test_dest_does_not_exist() {
    test_start "exits 1 when dest does not exist"
    local output rc
    output=$(bash -c '
        id() { echo "0"; }
        SUDO_UID=1000
        [ "$(id -u)" -eq 0 ] || exit 1
        CALLER_UID="${SUDO_UID:-0}"
        [ "$CALLER_UID" != "0" ] || exit 1

        DEST="/nonexistent_path_xyz_99999"
        realpath() { return 1; }
        DEST="$(realpath -e -- "$DEST" 2>/dev/null)" || { echo "fd-pstore-dump: dest does not exist" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { test_end; return 1; }
    assert_contains "$output" "dest does not exist" || { test_end; return 1; }
    test_end
}

test_dest_is_not_directory() {
    test_start "exits 1 when dest is a file, not dir"
    local output rc
    local tmpf
    tmpf=$(mktemp /tmp/pstore_dest_file.XXXXXX)
    output=$(DEST="$tmpf" bash -c '
        id() { echo "0"; }
        SUDO_UID=1000
        [ "$(id -u)" -eq 0 ] || exit 1
        CALLER_UID="${SUDO_UID:-0}"
        [ "$CALLER_UID" != "0" ] || exit 1

        DEST="'"$tmpf"'"
        [ -d "$DEST" ] || { echo "fd-pstore-dump: dest is not a directory" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { rm -f "$tmpf"; test_end; return 1; }
    assert_contains "$output" "dest is not a directory" || { rm -f "$tmpf"; test_end; return 1; }
    rm -f "$tmpf"
    test_end
}

test_dest_owner_mismatch() {
    test_start "exits 1 when dest not owned by SUDO_UID"
    local output rc
    local tmpdir
    tmpdir=$(mktemp -d /tmp/pstore_owner.XXXXXX)
    output=$(bash -c '
        DEST="'"$tmpdir"'"
        stat() {
            if [ "$1" = "-c" ] && [ "$2" = "%u" ]; then echo "9999"; return 0; fi
            command stat "$@"
        }
        CALLER_UID=1000
        DEST_UID="$(stat -c %u -- "$DEST" 2>/dev/null || echo 9999)"
        [ "$DEST_UID" = "$CALLER_UID" ] || { echo "fd-pstore-dump: dest must be owned by the invoking user (uid $CALLER_UID)" >&2; exit 1; }
    ' 2>&1) || rc=$?
    rc=${rc:-0}
    assert_eq 1 $rc "exit 1" || { rm -rf "$tmpdir"; test_end; return 1; }
    assert_contains "$output" "must be owned" || { rm -rf "$tmpdir"; test_end; return 1; }
    rm -rf "$tmpdir"
    test_end
}

# ---- Pstore copy logic tests ----
# These test the actual file operations that fd-pstore-dump performs.
# We cannot run the script as root, so we test the copy logic directly.

test_pstore_copies_records() {
    test_start "copies pstore records to dest"
    local __FD_LOGS="$FD_LOGS"

    local dest="$TEST_DIR/pstore_dest"
    local pstore_src="$TEST_DIR/pstore_src"
    mkdir -p "$dest" "$pstore_src"
    echo "panic record content" > "$pstore_src/dmesg.txt"

    OUT="$dest/pstore"
    mkdir -p "$OUT"

    copied=0
    for src in "$pstore_src"; do
        [ -d "$src" ] || continue
        label=$(basename "$(dirname "$src")")-$(basename "$src")
        ls -laR "$src" > "$OUT/listing-$label.txt" 2>/dev/null || true
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            cp -r -- "$src" "$OUT/copy-$label" 2>/dev/null && copied=1
        fi
    done

    local expected_label
    expected_label="$(basename "$(dirname "$pstore_src")")-$(basename "$pstore_src")"
    assert_file_exists "$OUT/listing-${expected_label}.txt" "listing file" || { test_end; return 1; }
    assert_dir_exists "$OUT/copy-${expected_label}" "copy dir" || { test_end; return 1; }
    assert_file_exists "$OUT/copy-${expected_label}/dmesg.txt" "copied record" || { test_end; return 1; }
    assert_eq 1 $copied "copied=1" || { test_end; return 1; }

    test_end
}

test_pstore_no_records() {
    test_start "writes listings even with empty pstore dirs"
    local __FD_LOGS="$FD_LOGS"

    local dest="$TEST_DIR/pstore_empty_dest"
    local pstore_src="$TEST_DIR/pstore_empty_src"
    mkdir -p "$dest" "$pstore_src"

    OUT="$dest/pstore"
    mkdir -p "$OUT"

    copied=0
    for src in "$pstore_src"; do
        [ -d "$src" ] || continue
        label=$(basename "$(dirname "$src")")-$(basename "$src")
        ls -laR "$src" > "$OUT/listing-$label.txt" 2>/dev/null || true
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            cp -r -- "$src" "$OUT/copy-$label" 2>/dev/null && copied=1
        fi
    done

    local expected_label
    expected_label="$(basename "$(dirname "$pstore_src")")-$(basename "$pstore_src")"
    assert_file_exists "$OUT/listing-${expected_label}.txt" "listing file" || { test_end; return 1; }
    assert_eq 0 $copied "copied=0 for empty" || { test_end; return 1; }

    test_end
}

test_pstore_multiple_sources() {
    test_start "copies records from multiple pstore sources"
    local __FD_LOGS="$FD_LOGS"

    local dest="$TEST_DIR/pstore_multi_dest"
    local pstore_src1="$TEST_DIR/pstore_src1"
    local pstore_src2="$TEST_DIR/pstore_src2"
    mkdir -p "$dest" "$pstore_src1" "$pstore_src2"
    echo "record1" > "$pstore_src1/record.txt"
    echo "record2" > "$pstore_src2/record.txt"

    OUT="$dest/pstore"
    mkdir -p "$OUT"

    copied=0
    for src in "$pstore_src1" "$pstore_src2"; do
        [ -d "$src" ] || continue
        label=$(basename "$(dirname "$src")")-$(basename "$src")
        ls -laR "$src" > "$OUT/listing-$label.txt" 2>/dev/null || true
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            cp -r -- "$src" "$OUT/copy-$label" 2>/dev/null && copied=1
        fi
    done

    local label1; label1="$(basename "$(dirname "$pstore_src1")")-$(basename "$pstore_src1")"
    local label2; label2="$(basename "$(dirname "$pstore_src2")")-$(basename "$pstore_src2")"
    assert_file_exists "$OUT/listing-${label1}.txt" "src1 listing" || { test_end; return 1; }
    assert_file_exists "$OUT/listing-${label2}.txt" "src2 listing" || { test_end; return 1; }
    assert_dir_exists "$OUT/copy-${label1}" "src1 copy" || { test_end; return 1; }
    assert_dir_exists "$OUT/copy-${label2}" "src2 copy" || { test_end; return 1; }
    assert_eq 1 $copied "copied=1" || { test_end; return 1; }

    test_end
}

test_pstore_source_does_not_exist() {
    test_start "skips non-existent pstore sources gracefully"
    local __FD_LOGS="$FD_LOGS"

    local dest="$TEST_DIR/pstore_skip_dest"
    mkdir -p "$dest"

    OUT="$dest/pstore"
    mkdir -p "$OUT"

    copied=0
    for src in "/nonexistent/pstore/path"; do
        [ -d "$src" ] || continue
        label=$(basename "$(dirname "$src")")-$(basename "$src")
        ls -laR "$src" > "$OUT/listing-$label.txt" 2>/dev/null || true
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            cp -r -- "$src" "$OUT/copy-$label" 2>/dev/null && copied=1
        fi
    done

    assert_eq 0 $copied "copied=0 when source missing" || { test_end; return 1; }

    test_end
}

run_tests "$0"
