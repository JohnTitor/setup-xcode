#!/usr/bin/env bash
set -euo pipefail

CANDIDATES_FILE=""

log() {
    printf '[setup-xcode] %s\n' "$*"
}

fail() {
    printf '[setup-xcode] error: %s\n' "$*" >&2
    exit 1
}

normalize_version() {
    local value="${1:-}"
    local major minor patch

    [[ "$value" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || return 1

    IFS='.' read -r major minor patch <<EOF
$value
EOF

    major=$((10#$major))
    minor=$((10#${minor:-0}))
    patch=$((10#${patch:-0}))

    printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}

version_key() {
    local normalized="${1:-}"
    local major minor patch

    IFS='.' read -r major minor patch <<EOF
$normalized
EOF

    printf '%05d%05d%05d\n' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
}

prefix_part_count() {
    local value="${1:-}"
    case "$value" in
        *.*.*) printf '3\n' ;;
        *.*) printf '2\n' ;;
        *) printf '1\n' ;;
    esac
}

version_prefix_matches() {
    local candidate="$1"
    local prefix="$2"
    local count="$3"
    local c1 c2 c3 p1 p2 p3

    IFS='.' read -r c1 c2 c3 <<EOF
$candidate
EOF
    IFS='.' read -r p1 p2 p3 <<EOF
$prefix
EOF

    case "$count" in
        1) [[ "$((10#$c1))" -eq "$((10#$p1))" ]] ;;
        2) [[ "$((10#$c1))" -eq "$((10#$p1))" && "$((10#$c2))" -eq "$((10#$p2))" ]] ;;
        3)
            [[ "$((10#$c1))" -eq "$((10#$p1))" && "$((10#$c2))" -eq "$((10#$p2))" && "$((10#$c3))" -eq "$((10#$p3))" ]]
            ;;
        *) return 1 ;;
    esac
}

extract_version_from_name() {
    local app_name="${1:-}"
    local stem="${app_name%.app}"

    if [[ "$stem" =~ ^Xcode_([0-9]+([.][0-9]+){0,2}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$stem" =~ ^Xcode[[:space:]_-]?([0-9]+([.][0-9]+){0,2})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

extract_version_from_plist() {
    local app_path="$1"
    local plist_path="$app_path/Contents/version.plist"
    local raw=""

    [[ -r "$plist_path" ]] || return 1

    if [[ -x /usr/libexec/PlistBuddy ]]; then
        raw=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null || true)
    fi

    if [[ -z "$raw" ]] && command -v plutil >/dev/null 2>&1; then
        raw=$(plutil -extract CFBundleShortVersionString raw "$plist_path" 2>/dev/null || true)
    fi

    if [[ -z "$raw" ]]; then
        raw=$(
            awk '
                /<key>CFBundleShortVersionString<\/key>/ { need_string = 1; next }
                need_string && match($0, /<string>([^<]+)<\/string>/, m) { print m[1]; exit }
            ' "$plist_path" 2>/dev/null || true
        )
    fi

    if [[ "$raw" =~ ^([0-9]+([.][0-9]+){0,2}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

classify_stability() {
    local app_name="${1:-}"
    local lower

    lower=$(printf '%s' "$app_name" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == *beta* || "$lower" == *release_candidate* || "$lower" == *preview* || "$lower" == *rc* ]]; then
        printf '0\n'
    else
        printf '1\n'
    fi
}

discover_xcodes() {
    local search_dirs raw_dirs candidate app_name raw_version normalized stable key
    local dir
    local -a dirs

    raw_dirs="${SETUP_XCODE_SEARCH_DIRS:-/Applications}"

    IFS=',' read -r -a dirs <<EOF
$raw_dirs
EOF

    for dir in "${dirs[@]}"; do
        dir="${dir%/}"
        [[ -d "$dir" ]] || continue

        shopt -s nullglob
        for candidate in "$dir"/Xcode*.app; do
            [[ -d "$candidate" ]] || continue
            [[ -L "$candidate" ]] && continue

            app_name=$(basename "$candidate")
            raw_version=""

            if raw_version=$(extract_version_from_name "$app_name" 2>/dev/null); then
                :
            elif raw_version=$(extract_version_from_plist "$candidate" 2>/dev/null); then
                :
            else
                continue
            fi

            normalized=$(normalize_version "$raw_version" 2>/dev/null || true)
            [[ -n "$normalized" ]] || continue

            stable=$(classify_stability "$app_name")
            key=$(version_key "$normalized")
            printf '%s|%s|%s|%s\n' "$key" "$normalized" "$stable" "$candidate"
        done
        shopt -u nullglob
    done
}

set_output() {
    local name="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
    fi
}

set_env_var() {
    local name="$1"
    local value="$2"
    local assignment

    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$name" "$value" >>"$GITHUB_ENV"
    else
        assignment="$name=$value"
        export "$assignment"
    fi
}

print_candidates() {
    local file="$1"
    local key version stable path channel

    if [[ ! -s "$file" ]]; then
        printf '  (none)\n'
        return 0
    fi

    sort -r "$file" | while IFS='|' read -r key version stable path; do
        channel="stable"
        if [[ "$stable" == "0" ]]; then
            channel="prerelease"
        fi
        printf '  - %s [%s] %s\n' "$version" "$channel" "$path"
    done
}

cleanup_candidates_file() {
    if [[ -n "${CANDIDATES_FILE:-}" && -f "${CANDIDATES_FILE:-}" ]]; then
        rm -f "$CANDIDATES_FILE"
    fi
}

main() {
    local selector selector_mode required_stability requested_version version_prefix_count
    local best_key="" best_version="" best_path="" best_stable=""
    local key version stable path
    local developer_dir
    local os_name

    selector="${XCODE_VERSION:-latest-stable}"
    selector="${selector#"${selector%%[![:space:]]*}"}"
    selector="${selector%"${selector##*[![:space:]]}"}"
    [[ -n "$selector" ]] || selector="latest-stable"

    if [[ "${SETUP_XCODE_TEST_MODE:-0}" != "1" ]]; then
        os_name=$(uname -s)
        [[ "$os_name" == "Darwin" ]] || fail "This action supports only macOS runners. Current OS: $os_name"
    fi

    selector_mode="version"
    required_stability="stable"
    requested_version=""
    version_prefix_count=0

    case "$selector" in
        latest)
            selector_mode="latest"
            required_stability="any"
            ;;
        latest-stable)
            selector_mode="latest"
            required_stability="stable"
            ;;
        *)
            if [[ "$selector" == *-beta ]]; then
                required_stability="prerelease"
                selector="${selector%-beta}"
            fi

            if [[ ! "$selector" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
                fail "Unsupported xcode-version '$selector'. Supported: latest, latest-stable, <major>, <major.minor>, <major.minor.patch>, and optional -beta suffix."
            fi

            requested_version=$(normalize_version "$selector") || fail "Invalid xcode-version '$selector'"
            version_prefix_count=$(prefix_part_count "$selector")
            ;;
    esac

    CANDIDATES_FILE=$(mktemp)
    trap cleanup_candidates_file EXIT
    discover_xcodes >"$CANDIDATES_FILE"

    if [[ ! -s "$CANDIDATES_FILE" ]]; then
        fail "No Xcode applications were found. Checked directories: ${SETUP_XCODE_SEARCH_DIRS:-/Applications}"
    fi

    while IFS='|' read -r key version stable path; do
        if [[ "$required_stability" == "stable" && "$stable" != "1" ]]; then
            continue
        fi
        if [[ "$required_stability" == "prerelease" && "$stable" != "0" ]]; then
            continue
        fi

        if [[ "$selector_mode" == "version" ]]; then
            if ! version_prefix_matches "$version" "$requested_version" "$version_prefix_count"; then
                continue
            fi
        fi

        if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
            best_key="$key"
            best_version="$version"
            best_stable="$stable"
            best_path="$path"
        fi
    done <"$CANDIDATES_FILE"

    if [[ -z "$best_path" ]]; then
        log "Selector '$XCODE_VERSION' did not match any installed Xcode."
        log "Available versions:"
        print_candidates "$CANDIDATES_FILE"
        exit 1
    fi

    developer_dir="$best_path/Contents/Developer"
    if [[ "${SETUP_XCODE_DRY_RUN:-0}" == "1" ]]; then
        log "Dry-run enabled: skipping xcode-select switch."
    else
        log "Switching to Xcode $best_version at $best_path"
        sudo xcode-select -s "$developer_dir" || fail "xcode-select failed for '$developer_dir'"
    fi

    set_env_var "MD_APPLE_SDK_ROOT" "$best_path"
    set_output "version" "$best_version"
    set_output "path" "$best_path"

    if [[ "$best_stable" == "1" ]]; then
        log "Selected stable Xcode $best_version ($best_path)"
    else
        log "Selected prerelease Xcode $best_version ($best_path)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
