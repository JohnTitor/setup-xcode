#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$ROOT_DIR/benchmark"
RESULTS_FILE="$RESULTS_DIR/results.csv"
REPEATS="${SETUP_XCODE_BENCH_REPEATS:-5}"
QUERIES_RAW="${SETUP_XCODE_BENCH_QUERIES:-latest-stable latest 16 16.4 16.4-beta}"

log() {
    printf '[benchmark] %s\n' "$*"
}

now_ms() {
    perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
}

median_from_stream() {
    local numbers_file count mid left right
    numbers_file="$(mktemp)"
    cat >"$numbers_file"

    count="$(wc -l <"$numbers_file" | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        rm -f "$numbers_file"
        return 1
    fi

    if (( count % 2 == 1 )); then
        mid=$((count / 2 + 1))
        sed -n "${mid}p" "$numbers_file"
    else
        left=$((count / 2))
        right=$((left + 1))
        awk -v a="$(sed -n "${left}p" "$numbers_file")" -v b="$(sed -n "${right}p" "$numbers_file")" 'BEGIN { printf "%.0f\n", (a+b)/2 }'
    fi

    rm -f "$numbers_file"
}

require_macos() {
    local os_name
    os_name="$(uname -s)"
    [[ "$os_name" == "Darwin" ]] || {
        log "This benchmark must run on macOS (found: $os_name)."
        exit 1
    }
}

prepare_baseline() {
    BASELINE_DIR="$(mktemp -d)"
    log "Cloning maxim-lobanov/setup-xcode baseline..."
    git clone --depth 1 https://github.com/maxim-lobanov/setup-xcode "$BASELINE_DIR/repo" >/dev/null 2>&1

    SHIM_DIR="$(mktemp -d)"
    cat >"$SHIM_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "xcode-select" && "${2:-}" == "-s" ]]; then
    exit 0
fi
exec /usr/bin/sudo "$@"
EOF
    chmod +x "$SHIM_DIR/sudo"
}

cleanup() {
    rm -rf "${BASELINE_DIR:-}" "${SHIM_DIR:-}"
}

run_candidate() {
    local query="$1"
    local out_file env_file
    local status=0
    out_file="$(mktemp)"
    env_file="$(mktemp)"

    XCODE_VERSION="$query" \
    SETUP_XCODE_DRY_RUN=1 \
    GITHUB_OUTPUT="$out_file" \
    GITHUB_ENV="$env_file" \
        "$ROOT_DIR/scripts/setup-xcode.sh" >/dev/null 2>&1 || status=$?

    rm -f "$out_file" "$env_file"
    return "$status"
}

run_baseline() {
    local query="$1"
    local out_file env_file
    local status=0
    out_file="$(mktemp)"
    env_file="$(mktemp)"

    PATH="$SHIM_DIR:$PATH" \
    GITHUB_OUTPUT="$out_file" \
    GITHUB_ENV="$env_file" \
    env "INPUT_XCODE-VERSION=$query" \
        node "$BASELINE_DIR/repo/dist/index.js" >/dev/null 2>&1 || status=$?

    rm -f "$out_file" "$env_file"
    return "$status"
}

time_impl() {
    local impl="$1"
    local query="$2"
    local iteration="$3"
    local start end duration status

    start="$(now_ms)"
    if [[ "$impl" == "candidate" ]]; then
        if run_candidate "$query"; then
            status="ok"
        else
            status="fail"
        fi
    else
        if run_baseline "$query"; then
            status="ok"
        else
            status="fail"
        fi
    fi
    end="$(now_ms)"
    duration=$((end - start))

    printf '%s,%s,%s,%s,%s\n' "$impl" "$query" "$iteration" "$status" "$duration" >>"$RESULTS_FILE"
    log "impl=$impl query=$query iteration=$iteration status=$status duration_ms=$duration"
}

main() {
    local query_list query iteration candidate_median baseline_median

    require_macos
    command -v node >/dev/null 2>&1 || {
        log "Node.js is required for baseline benchmarking."
        exit 1
    }

    mkdir -p "$RESULTS_DIR"
    printf 'impl,query,iteration,status,duration_ms\n' >"$RESULTS_FILE"

    trap cleanup EXIT
    prepare_baseline

    query_list="$QUERIES_RAW"
    for query in $query_list; do
        iteration=1
        while [[ "$iteration" -le "$REPEATS" ]]; do
            time_impl "baseline" "$query" "$iteration"
            time_impl "candidate" "$query" "$iteration"
            iteration=$((iteration + 1))
        done
    done

    baseline_median="$(
        awk -F, '$1=="baseline" && $4=="ok" {print $5}' "$RESULTS_FILE" | sort -n | median_from_stream || true
    )"
    candidate_median="$(
        awk -F, '$1=="candidate" && $4=="ok" {print $5}' "$RESULTS_FILE" | sort -n | median_from_stream || true
    )"

    if [[ -z "$baseline_median" || -z "$candidate_median" ]]; then
        log "Not enough successful samples to compare medians."
        log "Results saved to $RESULTS_FILE"
        exit 1
    fi

    log "Baseline median (ms):  $baseline_median"
    log "Candidate median (ms): $candidate_median"
    log "Results saved to $RESULTS_FILE"

    if [[ "$candidate_median" -ge "$baseline_median" ]]; then
        log "Candidate is not faster than baseline."
        exit 1
    fi

    log "Candidate median is faster than baseline."
}

main "$@"
