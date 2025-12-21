#!/bin/bash

# Verify CI gating system setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo "🔍 Verifying NorthstarDB CI Gating System Setup"
echo "================================================"

# Check 1: Benchmark harness build
echo -n "Checking if benchmark harness builds..."
if cd "$PROJECT_ROOT" && zig build >/dev/null 2>&1; then
    log_ok "Benchmark harness builds successfully"
else
    log_error "Benchmark harness build failed"
    exit 1
fi

# Check 2: Gate command exists
echo -n "Checking bench gate command..."
if [ -f "$PROJECT_ROOT/zig-out/bin/bench" ]; then
    help_output=$("$PROJECT_ROOT/zig-out/bin/bench" --help 2>&1)
    if echo "$help_output" | grep -q "gate <baseline>"; then
        log_ok "Gate command available"
    else
        log_error "Gate command not found in bench binary"
        echo "Help output was:"
        echo "$help_output"
        exit 1
    fi
else
    log_error "Bench binary not found"
    exit 1
fi

# Check 3: Baseline management script
echo -n "Checking baseline management script..."
if [ -f "$PROJECT_ROOT/scripts/manage_baselines.sh" ] && [ -x "$PROJECT_ROOT/scripts/manage_baselines.sh" ]; then
    log_ok "Baseline management script exists and executable"
else
    log_error "Baseline management script missing or not executable"
    exit 1
fi

# Check 4: Baselines directory structure
echo -n "Checking baselines directory structure..."
if [ -d "$PROJECT_ROOT/bench/baselines" ]; then
    if [ -d "$PROJECT_ROOT/bench/baselines/ci" ]; then
        baseline_count=$(find "$PROJECT_ROOT/bench/baselines/ci" -name "*.json" -type f | wc -l)
        if [ "$baseline_count" -gt 0 ]; then
            log_ok "CI baselines directory exists with $baseline_count baseline files"
        else
            log_warn "CI baselines directory exists but empty (will be auto-created)"
        fi
    else
        log_warn "CI baselines directory missing (will be auto-created)"
    fi
else
    log_warn "Baselines directory missing (will be auto-created)"
fi

# Check 5: GitHub Actions workflow
echo -n "Checking GitHub Actions workflow..."
if [ -f "$PROJECT_ROOT/.github/workflows/ci.yml" ]; then
    if grep -q "benchmark-gate" "$PROJECT_ROOT/.github/workflows/ci.yml"; then
        log_ok "CI workflow with benchmark gate exists"
    else
        log_error "CI workflow exists but missing benchmark gate"
        exit 1
    fi
else
    log_error "GitHub Actions workflow missing"
    exit 1
fi

# Check 6: Documentation
echo -n "Checking documentation..."
if [ -f "$PROJECT_ROOT/docs/ci_gating.md" ]; then
    log_ok "CI gating documentation exists"
else
    log_warn "CI gating documentation missing"
fi

# Check 7: Threshold implementation
echo -n "Checking threshold implementation in runner..."
if grep -q "max_throughput_regression_pct.*5.0" "$PROJECT_ROOT/src/bench/runner.zig"; then
    log_ok "CI thresholds implemented (throughput -5%, p99 +10%, alloc +5%, fsync 0%)"
else
    log_error "CI thresholds not found in runner"
    exit 1
fi

# Check 8: Critical benchmarks
echo -n "Checking for critical benchmarks..."
if grep -r "critical.*true" "$PROJECT_ROOT/src/bench/suite.zig" >/dev/null 2>&1; then
    critical_count=$(grep -c "critical.*true" "$PROJECT_ROOT/src/bench/suite.zig" || echo "0")
    log_ok "Found $critical_count critical benchmarks for gating"
else
    log_warn "No critical benchmarks found (gate will have no effect)"
fi

echo ""
echo "🎯 CI Gating System Status:"
echo "==========================="

# Overall status
issues=0

if [ ! -d "$PROJECT_ROOT/bench/baselines/ci" ] || [ -z "$(ls -A "$PROJECT_ROOT/bench/baselines/ci"/*.json 2>/dev/null || true)" ]; then
    log_warn "No CI baselines - gate will be skipped until baselines are established"
    echo "  → Push to main branch to establish initial baselines"
    issues=$((issues + 1))
else
    log_ok "CI baselines ready - gate will enforce performance thresholds"
fi

if command -v jq >/dev/null 2>&1; then
    log_ok "jq available for JSON processing"
else
    log_warn "jq not installed - required for baseline validation"
    echo "  → Install with: sudo apt-get install jq"
    issues=$((issues + 1))
fi

echo ""
if [ $issues -eq 0 ]; then
    log_ok "CI gating system is fully operational! 🚀"
    echo ""
    echo "Next steps:"
    echo "1. Make your changes"
    echo "2. Run tests: zig build test"
    echo "3. Test gate: ./scripts/manage_baselines.sh gate"
    echo "4. Push changes - CI will automatically gate regressions"
else
    log_warn "CI gating system has $issues issue(s) to resolve"
    echo ""
    echo "Required actions before CI gating is fully operational:"
    if [ ! -d "$PROJECT_ROOT/bench/baselines/ci" ]; then
        echo "- Push to main branch to establish initial baselines"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "- Install jq for JSON processing"
    fi
fi

echo ""
echo "📚 For detailed information, see: docs/ci_gating.md"