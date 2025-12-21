#!/bin/bash

# Baseline management script for NorthstarDB CI
# Usage: ./scripts/manage_baselines.sh [action] [suite] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BASELINES_DIR="$PROJECT_ROOT/bench/baselines"
CI_BASELINES_DIR="$BASELINES_DIR/ci"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}INFO${NC}: $1"
}

log_warn() {
    echo -e "${YELLOW}WARN${NC}: $1"
}

log_error() {
    echo -e "${RED}ERROR${NC}: $1"
}

# Build the benchmark harness
build_bench() {
    log_info "Building benchmark harness..."
    cd "$PROJECT_ROOT"
    zig build
}

# Generate baselines for a suite
generate_baselines() {
    local suite=${1:-micro}
    local repeats=${2:-5}
    local output_dir=${3:-"$CI_BASELINES_DIR"}

    log_info "Generating baselines for $suite suite ($repeats repeats)..."

    mkdir -p "$output_dir"

    # Run benchmarks and save to baselines
    ./zig-out/bin/bench run \
        --suite "$suite" \
        --repeats "$repeats" \
        --output "$output_dir" \
        --filter "micro/point_get|micro/point_put|micro/range_scan"

    # Move JSON files from per-repeat format to aggregated format
    for json_file in "$output_dir"/*_r*.json; do
        if [ -f "$json_file" ]; then
            # Extract base name (remove repeat suffix)
            base_name=$(echo "$json_file" | sed 's/_r[0-9]\{3\}\.json$//')
            mv "$json_file" "${base_name}.json"
        fi
    done

    log_info "Baselines generated in $output_dir"
}

# Validate baselines
validate_baselines() {
    local baselines_dir=${1:-"$CI_BASELINES_DIR"}

    if [ ! -d "$baselines_dir" ]; then
        log_error "Baselines directory not found: $baselines_dir"
        return 1
    fi

    local json_files=("$baselines_dir"/*.json)
    if [ ${#json_files[@]} -eq 0 ] || [ ! -f "${json_files[0]}" ]; then
        log_warn "No JSON baseline files found in $baselines_dir"
        return 1
    fi

    log_info "Found ${#json_files[@]} baseline files"

    # Validate JSON format
    for json_file in "${json_files[@]}"; do
        if [ -f "$json_file" ]; then
            if ! jq empty "$json_file" 2>/dev/null; then
                log_error "Invalid JSON in baseline file: $json_file"
                return 1
            fi
        fi
    done

    log_info "All baseline files are valid JSON"
    return 0
}

# Run benchmark gate
run_gate() {
    local baselines_dir=${1:-"$CI_BASELINES_DIR"}
    local suite=${2:-micro}

    if ! validate_baselines "$baselines_dir"; then
        log_warn "Cannot run gate: no valid baselines found"
        return 1
    fi

    log_info "Running benchmark gate for $suite suite..."

    # Create output directory for results
    local results_dir="$PROJECT_ROOT/bench/results/gate_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$results_dir"

    # Run the gate with error handling
    local exit_code=0
    ./zig-out/bin/bench gate "$baselines_dir" \
        --suite "$suite" \
        --repeats 3 \
        --output "$results_dir" 2>&1 | tee "$results_dir/gate.log" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_info "✅ Benchmark gate PASSED"
        return 0
    elif [ $exit_code -eq 1 ]; then
        # Check if it's a threshold failure (expected) or a benchmark error (unexpected)
        if grep -q "GATE FAILED" "$results_dir/gate.log"; then
            log_error "❌ Benchmark gate FAILED - performance regressions detected"
            log_warn "Check the gate log for details: $results_dir/gate.log"
            return 1
        else
            log_error "❌ Benchmark gate FAILED - benchmark errors encountered"
            log_warn "This may indicate implementation issues. Check the gate log: $results_dir/gate.log"
            return 2
        fi
    else
        log_error "❌ Benchmark gate FAILED - unexpected error (exit code: $exit_code)"
        log_warn "Check the gate log: $results_dir/gate.log"
        return $exit_code
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    generate [suite] [repeats] [output_dir]    Generate baselines (default: micro, 5 repeats)
    validate [baselines_dir]                  Validate baseline JSON files
    gate [baselines_dir] [suite]              Run benchmark gate
    build                                    Build benchmark harness only
    help                                    Show this help

Examples:
    $0 generate micro 5                      # Generate micro suite baselines
    $0 validate                              # Validate CI baselines
    $0 gate bench/baselines/ci micro         # Run gate for micro suite
    $0 build                                 # Just build the harness

Environment:
    PROJECT_ROOT: $PROJECT_ROOT
    BASELINES_DIR: $BASELINES_DIR
    CI_BASELINES_DIR: $CI_BASELINES_DIR
EOF
}

# Main script logic
main() {
    case "${1:-help}" in
        generate)
            build_bench
            generate_baselines "${2:-micro}" "${3:-5}" "${4:-$CI_BASELINES_DIR}"
            ;;
        validate)
            validate_baselines "${2:-$CI_BASELINES_DIR}"
            ;;
        gate)
            build_bench
            run_gate "${2:-$CI_BASELINES_DIR}" "${3:-micro}"
            ;;
        build)
            build_bench
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

# Install jq if not available
if ! command -v jq &> /dev/null; then
    log_info "Installing jq for JSON validation..."
    sudo apt-get update && sudo apt-get install -y jq
fi

main "$@"