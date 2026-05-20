#!/bin/bash
# setup_pace.sh
#
# Builds Hermes, MegaMmap, and the DDMD contact-map shim from source on PACE.
# Run this once inside an interactive allocation before any benchmark scripts.
#
# Usage:
#   bash scripts/setup_pace.sh
#
# After this completes, source the generated env file before running tests:
#   source $INSTALL_ROOT/mega_env.sh

set -uo pipefail   # note: no -e here — module commands can return non-zero

# ---------------------------------------------------------------------------
# Kill the GUI askpass helper — headless compute nodes have no display,
# so git would hang/fail trying to pop a credential dialog.
# ---------------------------------------------------------------------------
unset SSH_ASKPASS GIT_ASKPASS DISPLAY 2>/dev/null || true
export GIT_TERMINAL_PROMPT=0   # fail fast instead of prompting if auth is needed

# ---------------------------------------------------------------------------
# Make 'module' available in this non-interactive script
# ---------------------------------------------------------------------------
LMOD_INIT=/usr/local/pace-apps/lmod/lmod/init/bash
if [ -f "$LMOD_INIT" ]; then
    # Suppress the conda-not-found noise from lmod init
    source "$LMOD_INIT" 2>/dev/null || true
else
    echo "ERROR: lmod init not found at $LMOD_INIT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths — adjust INSTALL_ROOT if you prefer a different location
# ---------------------------------------------------------------------------
SCRATCH=/storage/home/hcoda1/7/avandevoorde3/scratch
INSTALL_ROOT=$SCRATCH/mega_stack   # Hermes + MegaMmap installs land here
SRC_ROOT=$SCRATCH/mega_src         # cloned source trees
AGENT_HPC_ROOT=${AGENT_HPC_ROOT:-$(realpath "$(dirname "$0")/../..")}

mkdir -p "$INSTALL_ROOT" "$SRC_ROOT"

# ---------------------------------------------------------------------------
# Load PACE modules — auto-detect latest available version of each tool
# ---------------------------------------------------------------------------
module purge 2>/dev/null || true

_load_latest() {
    local name=$1
    local ver
    ver=$(module spider "$name" 2>&1 \
        | grep -oP "${name}/[0-9][^\s]*" \
        | sort -V | tail -1) || true
    if [ -z "$ver" ]; then
        echo "WARNING: no module found for '$name' — skipping" >&2
        return 0
    fi
    # Check if this version has prerequisites and load them first
    local prereq
    prereq=$(module spider "$ver" 2>&1 \
        | grep -A10 "You will need to load" \
        | grep -v "You will need" \
        | grep -v "^--" \
        | grep -E "^\s+\S+/\S+" \
        | head -1 \
        | xargs) || true
    if [ -n "$prereq" ]; then
        echo "==>   loading prerequisite: $prereq (needed by $ver)"
        module load $prereq 2>&1 || { echo "WARNING: failed to load prereq $prereq" >&2; return 0; }
    fi
    echo "==>   loading $ver"
    module load "$ver" 2>&1 || echo "WARNING: failed to load $ver" >&2
}

_load_latest gcc
_load_latest cmake
_load_latest openmpi
_load_latest cuda

echo "==> Modules loaded"
set -e   # re-enable exit-on-error for the build steps

# ---------------------------------------------------------------------------
# 1. HermesShm  (required by Hermes and MegaMmap)
# ---------------------------------------------------------------------------
if [ ! -f "$INSTALL_ROOT/lib/libhermes_shm_data_structures.so" ] && \
   [ ! -d "$INSTALL_ROOT/include/hermes_shm" ]; then
    echo "==> Cloning HermesShm..."
    cd "$SRC_ROOT"
    git clone --depth=1 https://github.com/hyoklee/cte-hermes-shm hermes_shm
    cd hermes_shm
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> HermesShm installed"
else
    echo "==> HermesShm already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 2. Hermes (GRC-IIT version — NOT HDF Group's Hermes)
# ---------------------------------------------------------------------------
if [ ! -f "$INSTALL_ROOT/lib/libhermes.so" ]; then
    echo "==> Cloning Hermes (GRC-IIT)..."
    cd "$SRC_ROOT"
    git clone --depth=1 https://github.com/grc-iit/hermes hermes
    cd hermes
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$INSTALL_ROOT" \
        -DHermesShm_DIR="$INSTALL_ROOT/lib/cmake/HermesShm"
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> Hermes installed"
else
    echo "==> Hermes already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 3. MegaMmap
# ---------------------------------------------------------------------------
if [ ! -d "$INSTALL_ROOT/include/mega_mmap" ]; then
    echo "==> Cloning MegaMmap..."
    cd "$SRC_ROOT"
    git clone --depth=1 https://github.com/grc-iit/mega_mmap mega_mmap
    cd mega_mmap
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$INSTALL_ROOT"
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> MegaMmap installed"
else
    echo "==> MegaMmap already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 4. DDMD contact-map shim
# ---------------------------------------------------------------------------
SHIM_DIR="$AGENT_HPC_ROOT/mega_mmap_integration/ddmd/shims"
SHIM_BIN="$SHIM_DIR/build/ddmd_contact_map_loader"

if [ ! -f "$SHIM_BIN" ]; then
    echo "==> Building DDMD shim..."
    cmake -S "$SHIM_DIR" -B "$SHIM_DIR/build" \
        -DMEGAMMAP_ROOT="$SRC_ROOT/mega_mmap" \
        -DHERMES_ROOT="$INSTALL_ROOT" \
        -DCMAKE_PREFIX_PATH="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$SHIM_DIR/build" -j"$(nproc)"
    echo "==> DDMD shim built: $SHIM_BIN"
else
    echo "==> DDMD shim already built, skipping"
fi

# ---------------------------------------------------------------------------
# 4. Write env file to source before running tests
# ---------------------------------------------------------------------------
ENV_FILE="$INSTALL_ROOT/mega_env.sh"
cat > "$ENV_FILE" <<EOF
# Auto-generated by setup_pace.sh — source this before running benchmarks
export AGENT_HPC_ROOT=$AGENT_HPC_ROOT
export INSTALL_ROOT=$INSTALL_ROOT

# MegaMmap / Hermes
export HERMES_ROOT=$INSTALL_ROOT
export LD_LIBRARY_PATH=$INSTALL_ROOT/lib:\${LD_LIBRARY_PATH:-}
export PATH=$INSTALL_ROOT/bin:\$PATH

# DDMD shim
export MEGA_SHIM=$SHIM_BIN
export MEGA_WORKDIR=$SCRATCH/mega_ddmd
export MEGA_WINDOW=256m
export MEGA_NPROCS=1

# AtomAgents Hermes interception
export HERMES_INTERCEPTOR=$INSTALL_ROOT/lib/libhermes_posix.so
export MEGA_WORKDIR_ATOMAGENTS=$SCRATCH/mega_atomagents

# PACE modules — reload latest available versions in new shells
for _mod in gcc cmake openmpi cuda; do
    _ver=\$(module spider "\$_mod" 2>&1 | grep -oP "\${_mod}/[0-9][^\s]*" | sort -V | tail -1)
    [ -n "\$_ver" ] && module load "\$_ver"
done
unset _mod _ver
EOF

echo ""
echo "==> Setup complete."
echo "    Source the env file before running tests:"
echo "      source $ENV_FILE"
