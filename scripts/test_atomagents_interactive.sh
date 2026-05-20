#!/bin/bash
# test_atomagents_interactive.sh
#
# Interactive test launcher for AtomAgents Exp2 + MegaMmap.
# Run inside an salloc session after sourcing mega_env.sh.
#
# Usage:
#   source $INSTALL_ROOT/mega_env.sh
#   bash scripts/test_atomagents_interactive.sh [--window 4g] [--hw-profile l40s]
#
# Outputs:
#   $RESULTS_DIR/stats_dict.csv   — benchmark row
#
# Note: HERMES_INTERCEPTOR must point to libhermes_posix.so.
#       If unset or missing, the workload runs without MegaMmap buffering
#       (metrics-only baseline mode).

set -euo pipefail

RESULTS_DIR=${RESULTS_DIR:-$AGENT_HPC_ROOT/mega_mmap_integration/results}
WINDOW=${MEGA_WINDOW:-4g}    # LLM weights are large; recommend >=4g
HW_PROFILE=l40s
NPROCS=1
EXTRA_ARGS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --window)      WINDOW="$2";     shift 2 ;;
        --hw-profile)  HW_PROFILE="$2"; shift 2 ;;
        --nprocs)      NPROCS="$2";     shift 2 ;;
        --extra)       EXTRA_ARGS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ -z "${AGENT_HPC_ROOT:-}" ]; then
    echo "ERROR: AGENT_HPC_ROOT not set. Source mega_env.sh first."
    exit 1
fi

EXP2_SCRIPT="$AGENT_HPC_ROOT/runtime/demo/cluster_atomagents_exp2.py"
if [ ! -f "$EXP2_SCRIPT" ]; then
    echo "ERROR: cluster_atomagents_exp2.py not found at $EXP2_SCRIPT"
    echo "  Check that AGENT_HPC_ROOT points to the agent_hpc repo root."
    exit 1
fi

INTERCEPTOR=${HERMES_INTERCEPTOR:-}
if [ -z "$INTERCEPTOR" ] || [ ! -f "$INTERCEPTOR" ]; then
    echo "WARNING: HERMES_INTERCEPTOR not set or not found — running WITHOUT MegaMmap buffering"
    echo "         This is still useful as a metrics-only baseline."
else
    echo "==> Hermes interceptor: $INTERCEPTOR"
fi

echo "==> AtomAgents Exp2 + MegaMmap test"
echo "    Window     : $WINDOW"
echo "    HW profile : $HW_PROFILE"
echo "    Results    : $RESULTS_DIR/stats_dict.csv"
echo ""

mkdir -p "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# Start Hermes daemon (needed even for interceptor mode)
# ---------------------------------------------------------------------------
if [ -n "$INTERCEPTOR" ] && [ -f "$INTERCEPTOR" ]; then
    echo "==> Starting Hermes daemon..."
    hermes_daemon &
    HERMES_PID=$!
    sleep 5
    echo "    Hermes PID: $HERMES_PID"

    cleanup() {
        echo "==> Stopping Hermes daemon..."
        kill "$HERMES_PID" 2>/dev/null || true
    }
    trap cleanup EXIT
fi

# ---------------------------------------------------------------------------
# Run agentic variant (LLM-steered, observe_only)
# ---------------------------------------------------------------------------
echo "==> Running agentic variant (observe_only)..."
MEGA_WINDOW=$WINDOW \
HERMES_INTERCEPTOR=${INTERCEPTOR:-} \
MEGA_WORKDIR=${MEGA_WORKDIR_ATOMAGENTS:-/tmp/mega_atomagents} \
python "$AGENT_HPC_ROOT/mega_mmap_integration/atomagents_exp2/run_agentic.py" \
    --stats-csv "$RESULTS_DIR/stats_dict.csv" \
    --nprocs "$NPROCS" \
    -- --hw-profile "$HW_PROFILE" $EXTRA_ARGS

echo ""

# ---------------------------------------------------------------------------
# Run non-agentic variant (LAMMPS baseline)
# ---------------------------------------------------------------------------
echo "==> Running non-agentic variant (baseline)..."
MEGA_WINDOW=$WINDOW \
HERMES_INTERCEPTOR=${INTERCEPTOR:-} \
MEGA_WORKDIR=${MEGA_WORKDIR_ATOMAGENTS:-/tmp/mega_atomagents} \
python "$AGENT_HPC_ROOT/mega_mmap_integration/atomagents_exp2/run_noai.py" \
    --stats-csv "$RESULTS_DIR/stats_dict.csv" \
    --nprocs "$NPROCS" \
    -- --hw-profile "$HW_PROFILE" $EXTRA_ARGS

echo ""
echo "==> Done. Results written to $RESULTS_DIR/stats_dict.csv"
cat "$RESULTS_DIR/stats_dict.csv"
