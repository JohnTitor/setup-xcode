#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/setup-xcode.sh"

PASS_COUNT=0
FAIL_COUNT=0

log() {
    printf '[test] %s\n' "$*"
}

record_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $*"
}

record_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $*"
}

mk_xcode_app() {
    local root="$1"
    local app_name="$2"
    local plist_version="${3:-}"
    local app_dir="$root/$app_name"

    mkdir -p "$app_dir/Contents"
    if [[ -n "$plist_version" ]]; then
        cat >"$app_dir/Contents/version.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>$plist_version</string>
</dict>
</plist>
EOF
    fi
}

run_action() {
    local apps_dir="$1"
    local selector="$2"
    local output_file="$3"
    local log_file="$4"

    XCODE_VERSION="$selector" \
    SETUP_XCODE_TEST_MODE=1 \
    SETUP_XCODE_DRY_RUN=1 \
    SETUP_XCODE_SEARCH_DIRS="$apps_dir" \
    GITHUB_OUTPUT="$output_file" \
        "$SCRIPT" >"$log_file" 2>&1
}

output_value() {
    local output_file="$1"
    local key="$2"
    grep -E "^${key}=" "$output_file" | head -n 1 | cut -d '=' -f 2-
}

test_latest_stable_prefers_stable() {
    local tmp output log_file version path
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "Xcode_16.4.app"
    mk_xcode_app "$tmp" "Xcode_16.5_beta.app"

    if run_action "$tmp" "latest-stable" "$output" "$log_file"; then
        version="$(output_value "$output" "version")"
        path="$(output_value "$output" "path")"
        if [[ "$version" == "16.4.0" && "$path" == "$tmp/Xcode_16.4.app" ]]; then
            record_pass "latest-stable chooses highest stable"
        else
            record_fail "latest-stable result mismatch (version=$version path=$path)"
        fi
    else
        record_fail "latest-stable execution failed"
        cat "$log_file"
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

test_latest_includes_prerelease() {
    local tmp output log_file version
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "Xcode_16.4.app"
    mk_xcode_app "$tmp" "Xcode_16.5_beta.app"

    if run_action "$tmp" "latest" "$output" "$log_file"; then
        version="$(output_value "$output" "version")"
        if [[ "$version" == "16.5.0" ]]; then
            record_pass "latest includes prerelease"
        else
            record_fail "latest expected 16.5.0 but got $version"
        fi
    else
        record_fail "latest execution failed"
        cat "$log_file"
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

test_prefix_selects_highest_patch() {
    local tmp output log_file version path
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "Xcode_16.4.app"
    mk_xcode_app "$tmp" "Xcode_16.4.2.app"
    mk_xcode_app "$tmp" "Xcode_16.4_beta.app"

    if run_action "$tmp" "16.4" "$output" "$log_file"; then
        version="$(output_value "$output" "version")"
        path="$(output_value "$output" "path")"
        if [[ "$version" == "16.4.2" && "$path" == "$tmp/Xcode_16.4.2.app" ]]; then
            record_pass "prefix selector chooses highest stable patch"
        else
            record_fail "prefix selector mismatch (version=$version path=$path)"
        fi
    else
        record_fail "prefix selector execution failed"
        cat "$log_file"
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

test_beta_suffix_filters_prerelease() {
    local tmp output log_file version path
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "Xcode_16.4.app"
    mk_xcode_app "$tmp" "Xcode_16.4_beta.app"

    if run_action "$tmp" "16.4-beta" "$output" "$log_file"; then
        version="$(output_value "$output" "version")"
        path="$(output_value "$output" "path")"
        if [[ "$version" == "16.4.0" && "$path" == "$tmp/Xcode_16.4_beta.app" ]]; then
            record_pass "beta suffix selects prerelease"
        else
            record_fail "beta suffix mismatch (version=$version path=$path)"
        fi
    else
        record_fail "beta suffix execution failed"
        cat "$log_file"
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

test_plist_fallback() {
    local tmp output log_file version path
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "XcodeCustom.app" "15.2"
    mk_xcode_app "$tmp" "Xcode_15.1.app"

    if run_action "$tmp" "15.2" "$output" "$log_file"; then
        version="$(output_value "$output" "version")"
        path="$(output_value "$output" "path")"
        if [[ "$version" == "15.2.0" && "$path" == "$tmp/XcodeCustom.app" ]]; then
            record_pass "plist fallback extracts version"
        else
            record_fail "plist fallback mismatch (version=$version path=$path)"
        fi
    else
        record_fail "plist fallback execution failed"
        cat "$log_file"
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

test_rejects_complex_ranges() {
    local tmp output log_file
    tmp="$(mktemp -d)"
    output="$(mktemp)"
    log_file="$(mktemp)"

    mk_xcode_app "$tmp" "Xcode_16.4.app"

    if run_action "$tmp" "^16.4.0" "$output" "$log_file"; then
        record_fail "complex range unexpectedly succeeded"
    else
        if grep -q "Unsupported xcode-version" "$log_file"; then
            record_pass "complex ranges are rejected"
        else
            record_fail "complex range error message mismatch"
            cat "$log_file"
        fi
    fi

    rm -rf "$tmp" "$output" "$log_file"
}

main() {
    test_latest_stable_prefers_stable
    test_latest_includes_prerelease
    test_prefix_selects_highest_patch
    test_beta_suffix_filters_prerelease
    test_plist_fallback
    test_rejects_complex_ranges

    log "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT"
    if [[ "$FAIL_COUNT" -ne 0 ]]; then
        exit 1
    fi
}

main "$@"
