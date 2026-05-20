#!/bin/bash
# test_ddmd_interactive.sh
#
# Interactive test launcher for DeepDriveMD + MegaMmap.
# Run inside an salloc session after sourcing mega_env.sh.
#
# Usage:
#   source $INSTALL_ROOT/mega_env.sh
#   bash scripts/test_ddmd_interactive.sh --config /path/to/experiment.yaml [--window 4g] [--nprocs 1]
#
# Outputs:
#   $RESULTS_DIR/stats_dict.csv   — benchmark row
#   stdout                        — shim runtime and alive pings

set -euo pipefail

RESULTS_DIR=${RESULTS_DIR:-$AGENT_HPC_ROOT/mega_mmap_integration/results}
WINDOW=256m
NPROCS=1
CONFIG=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)  CONFIG="$2";  shift 2 ;;
        --window)  WINDOW="$2";  shift 2 ;;
        --nprocs)  NPROCS="$2";  shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$CONFIG" ]; then
    echo "ERROR: --config is required"
    echo "Usage: $0 --config /path/to/experiment.yaml [--window 4g] [--nprocs 1]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ -z "${MEGA_SHIM:-}" ] || [ ! -f "$MEGA_SHIM" ]; then
    echo "ERROR: MEGA_SHIM not set or binary not found: '${MEGA_SHIM:-}'"
    echo "  Run setup_pace.sh and source mega_env.sh first."
    exit 1
fi

if [ -z "${HERMES_ROOT:-}" ]; then
    echo "ERROR: HERMES_ROOT not set. Source mega_env.sh first."
    exit 1
fi

echo "==> DeepDriveMD + MegaMmap test"
echo "    Config     : $CONFIG"
echo "    Window     : $WINDOW"
echo "    Nprocs     : $NPROCS"
echo "    Shim       : $MEGA_SHIM"
echo "    Results    : $RESULTS_DIR/stats_dict.csv"
echo ""

mkdir -p "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# Start Hermes daemon
# ---------------------------------------------------------------------------
echo "==> Starting Hermes daemon..."
hermes_daemon &
HERMES_PID=$!
sleep 3
echo "    Hermes PID: $HERMES_PID"

cleanup() {
    echo "==> Stopping Hermes daemon..."
    kill "$HERMES_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Run agentic variant
# ---------------------------------------------------------------------------
echo "==> Running agentic variant..."
MEGA_WINDOW=$WINDOW \
MEGA_SHIM=$MEGA_SHIM \
MEGA_WORKDIR=${MEGA_WORKDIR:-/tmp/mega_ddmd} \
MEGA_NPROCS=$NPROCS \
python "$AGENT_HPC_ROOT/mega_mmap_integration/ddmd/run_agentic.py" \
    --config "$CONFIG" \
    --stats-csv "$RESULTS_DIR/stats_dict.csv" \
    --window-gb "$(python3 -c "s='$WINDOW'.lower(); print(float(s[:-1]) if s.endswith('g') else float(s[:-1])/1024)")" \
    --nprocs "$NPROCS"

echo ""

# ---------------------------------------------------------------------------
# Run non-agentic variant
# ---------------------------------------------------------------------------
echo "==> Running non-agentic variant..."
MEGA_WINDOW=$WINDOW \
MEGA_SHIM=$MEGA_SHIM \
MEGA_WORKDIR=${MEGA_WORKDIR:-/tmp/mega_ddmd} \
MEGA_NPROCS=$NPROCS \
python "$AGENT_HPC_ROOT/mega_mmap_integration/ddmd/run_noai.py" \
    --config "$CONFIG" \
    --stats-csv "$RESULTS_DIR/stats_dict.csv" \
    --window-gb "$(python3 -c "s='$WINDOW'.lower(); print(float(s[:-1]) if s.endswith('g') else float(s[:-1])/1024)")" \
    --nprocs "$NPROCS"

echo ""
echo "==> Done. Results written to $RESULTS_DIR/stats_dict.csv"
cat "$RESULTS_DIR/stats_dict.csv"
