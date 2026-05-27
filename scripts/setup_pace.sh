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
_load_latest boost   # needed by Hermes (Boost::fiber)

echo "==> Modules loaded"
set -e   # re-enable exit-on-error for the build steps

# ---------------------------------------------------------------------------
# 0-pre. Boost with fiber  (PACE spack boost omits fiber; build from source)
# ---------------------------------------------------------------------------
# Check that our custom Boost has both fiber and regex cmake configs
_boost_component_missing() {
    local comp=$1
    for _f in "$INSTALL_ROOT"/lib/cmake/boost_${comp}-*/boost_${comp}-config.cmake \
               "$INSTALL_ROOT"/lib64/cmake/boost_${comp}-*/boost_${comp}-config.cmake; do
        [ -f "$_f" ] && return 1
    done
    return 0
}

_boost_config_missing() {
    for _f in "$INSTALL_ROOT"/lib/cmake/Boost-*/BoostConfig.cmake \
               "$INSTALL_ROOT"/lib64/cmake/Boost-*/BoostConfig.cmake; do
        [ -f "$_f" ] && return 1
    done
    return 0
}

BOOST_LIBS=fiber,context,thread,system,atomic,chrono,date_time,filesystem,regex

if _boost_config_missing || _boost_component_missing fiber || _boost_component_missing regex; then
    echo "==> Building Boost with fiber+regex (PACE spack version lacks fiber)..."
    BOOST_VER=1_83_0
    BOOST_TAR=boost_${BOOST_VER}.tar.gz
    cd "$SRC_ROOT"
    if [ ! -f "$BOOST_TAR" ]; then
        curl -L -O "https://archives.boost.io/release/1.83.0/source/$BOOST_TAR"
    fi
    if [ ! -d "boost_${BOOST_VER}" ]; then
        tar xf "$BOOST_TAR"
    fi
    cd "boost_${BOOST_VER}"
    ./bootstrap.sh --prefix="$INSTALL_ROOT" --with-libraries=$BOOST_LIBS
    ./b2 install -j"$(nproc)" variant=release link=shared threading=multi
    echo "==> Boost with fiber+regex installed"
else
    echo "==> Boost (with fiber+regex) already installed, skipping"
fi

# Helper: find any cmake config file for a package across common install prefixes
_cmake_installed() {
    local pkg=$1; shift          # remaining args are config filenames to check
    for cfg in "$@"; do
        for base in lib lib64 share; do
            [ -f "$INSTALL_ROOT/$base/cmake/$pkg/$cfg" ] && return 0
        done
    done
    return 1
}

# Helper: clone only if the source dir doesn't exist yet
_clone_if_needed() {
    local dir=$1 url=$2; shift 2  # remaining args forwarded to git clone
    if [ ! -d "$SRC_ROOT/$dir" ]; then
        git clone --depth=1 "$@" "$url" "$SRC_ROOT/$dir"
    else
        echo "    (source dir $dir already present, skipping clone)"
    fi
}

# ---------------------------------------------------------------------------
# 0. Catch2 v3
# ---------------------------------------------------------------------------
if ! _cmake_installed Catch2 Catch2Config.cmake catch2Config.cmake; then
    echo "==> Building Catch2..."
    _clone_if_needed catch2 https://github.com/catchorg/Catch2 --branch v3.5.4
    cd "$SRC_ROOT/catch2"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCATCH_INSTALL_DOCS=OFF \
        -DCATCH_BUILD_TESTING=OFF
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> Catch2 installed"
else
    echo "==> Catch2 already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 0b. yaml-cpp
# ---------------------------------------------------------------------------
if ! _cmake_installed yaml-cpp yaml-cppConfig.cmake yaml-cpp-config.cmake; then
    echo "==> Building yaml-cpp..."
    _clone_if_needed yaml-cpp https://github.com/jbeder/yaml-cpp
    cd "$SRC_ROOT/yaml-cpp"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DYAML_CPP_BUILD_TESTS=OFF \
        -DYAML_CPP_BUILD_TOOLS=OFF
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> yaml-cpp installed"
else
    echo "==> yaml-cpp already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 0c. cereal  (header-only)
# ---------------------------------------------------------------------------
if ! _cmake_installed cereal cerealConfig.cmake cereal-config.cmake; then
    echo "==> Building cereal..."
    _clone_if_needed cereal https://github.com/USCiLab/cereal --branch v1.3.2
    cd "$SRC_ROOT/cereal"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DJUST_INSTALL_CEREAL=ON \
        -DBUILD_DOC=OFF \
        -DBUILD_SANDBOX=OFF \
        -DBUILD_TESTS=OFF
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> cereal installed"
else
    echo "==> cereal already installed, skipping"
fi

# ---------------------------------------------------------------------------
# 1. HermesShm  (required by Hermes and MegaMmap)
# ---------------------------------------------------------------------------
# grc-iit/hermes_shm has pod_array.h and is what grc-iit/hermes was built for.
# hyoklee/cte-hermes-shm merged iowarp and removed pod_array.h on main.
# The v0.0.0-alpha tag of hyoklee pre-dates that removal and works correctly.
_clone_hermes_shm() {
    # If source exists and already has pod_array.h, nothing to do
    if [ -d "$SRC_ROOT/hermes_shm" ] && \
       git -C "$SRC_ROOT/hermes_shm" cat-file -e \
           HEAD:include/hermes_shm/data_structures/ipc/pod_array.h 2>/dev/null; then
        echo "    (hermes_shm source already at correct version)"
        return
    fi
    # Wipe any incorrect/partial clone so we can start fresh
    rm -rf "$SRC_ROOT/hermes_shm"
    echo "    Trying grc-iit/hermes_shm..."
    if git clone --depth=1 https://github.com/grc-iit/hermes_shm \
           "$SRC_ROOT/hermes_shm" 2>/dev/null; then
        echo "    grc-iit/hermes_shm cloned"
        return
    fi
    # Fall back to the pre-iowarp v0.0.0-alpha tag of hyoklee/cte-hermes-shm.
    # The current main branch merged iowarp which removed pod_array.h.
    echo "    grc-iit unavailable; using hyoklee/cte-hermes-shm@v0.0.0-alpha (has pod_array.h)..."
    git clone --depth=1 --branch v0.0.0-alpha \
        https://github.com/hyoklee/cte-hermes-shm "$SRC_ROOT/hermes_shm"
}

# Install is complete when pod_array.h and at least one runtime lib are present.
# hyoklee installs libhermes_shm_host.so; grc-iit installs libhermes_shm_data_structures.so.
_hermes_shm_complete() {
    { [ -f "$INSTALL_ROOT/lib/libhermes_shm_data_structures.so" ] \
   || [ -f "$INSTALL_ROOT/lib/libhermes_shm_host.so" ]; } \
    && [ -f "$INSTALL_ROOT/include/hermes_shm/data_structures/ipc/pod_array.h" ]
}

if ! _hermes_shm_complete; then
    echo "==> Building HermesShm..."
    _clone_hermes_shm
    cd "$SRC_ROOT/hermes_shm"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DHERMES_SHM_ENABLE_TESTING=OFF
    cmake --build build -j"$(nproc)"
    cmake --install build
    echo "==> HermesShm installed"
else
    echo "==> HermesShm already installed, skipping"
fi

# data_structure.h is a later-added umbrella; v0.0.0-alpha ships all.h instead.
# Forward to it so grc-iit/hermes@master can compile.
_DATA_STRUCT_H="$INSTALL_ROOT/include/hermes_shm/data_structures/data_structure.h"
if [ ! -f "$_DATA_STRUCT_H" ]; then
    echo "==> Injecting missing data_structure.h (forwards to all.h)..."
    printf '#ifndef HERMES_DATA_STRUCTURES_DATA_STRUCTURE_H_\n#define HERMES_DATA_STRUCTURES_DATA_STRUCTURE_H_\n#include "all.h"\n#endif\n' \
        > "$_DATA_STRUCT_H"
    echo "    data_structure.h injected at $_DATA_STRUCT_H"
fi

# grc-iit/hermes@master was written against a newer hermes_shm that split queue
# types into individual files and added a containers/ directory. v0.0.0-alpha
# keeps them in ring_queue.h / ring_ptr_queue.h / ipc/. Stub the missing paths.
_DS="$INSTALL_ROOT/include/hermes_shm/data_structures"
mkdir -p "$_DS/containers"

_inject_stub() {
    local dst=$1; shift
    [ -f "$dst" ] && return 0
    printf '%s\n' "$@" > "$dst"
    echo "    stubbed: $dst"
}

echo "==> Injecting missing hermes_shm API shims..."

# ipc/ queue headers split out from ring_queue/ring_ptr_queue in newer versions
_inject_stub "$_DS/ipc/mpsc_queue.h" \
    '#pragma once' '#include "ring_queue.h"'
_inject_stub "$_DS/ipc/mpsc_ptr_queue.h" \
    '#pragma once' '#include "ring_ptr_queue.h"'

# serialization/shm_serialize.h renamed to local_serialize.h in v0.0.0-alpha
_inject_stub "$_DS/serialization/shm_serialize.h" \
    '#pragma once' \
    '#include "local_serialize.h"' \
    '#include "serialize_common.h"'

# containers/ directory didn't exist; types are in ipc/ (or already in all.h)
_inject_stub "$_DS/containers/spsc_queue.h" \
    '#pragma once' '#include "../ipc/ring_queue.h"'
_inject_stub "$_DS/containers/split_ticket_queue.h" \
    '#pragma once' '#include "../ipc/split_ticket_queue.h"'
_inject_stub "$_DS/containers/charbuf.h" \
    '#pragma once' '#include "../ipc/chararr.h"'
_inject_stub "$_DS/containers/converters.h" \
    '#pragma once' '/* converters provided transitively via data_structure.h -> all.h */'

# config_parse.h in v0.0.0-alpha doesn't include logging.h, so HILOG is not
# in scope when grc-iit/hermes config.h compiles. Also, v0.0.0-alpha's HILOG
# uses a different signature (SUB_CODE, ...) vs the new (verbosity, ...).
# Patch config_parse.h: include logging.h, then redefine HILOG as a no-op.
# config_parse.h already includes logging.h in v0.0.0-alpha, but logging.h's
# HILOG expands to HLOG(...) which is never defined, causing "expected ';'"
# errors. Redefine HILOG as a no-op immediately after the logging.h include.
_CONFIG_PARSE="$INSTALL_ROOT/include/hermes_shm/util/config_parse.h"
if ! grep -q '#define HILOG(...)' "$_CONFIG_PARSE"; then
    awk '/#include "logging.h"/ {
        print
        print "// HILOG compat: v0.0.0-alpha HILOG expands to HLOG which is undefined;"
        print "// redefine as no-op to match new (verbosity,...) calling convention."
        print "#undef HILOG"
        print "#define HILOG(...)"
        next
    } { print }' "$_CONFIG_PARSE" > "${_CONFIG_PARSE}.tmp" \
        && mv "${_CONFIG_PARSE}.tmp" "$_CONFIG_PARSE"
    echo "    Patched config_parse.h: HILOG no-op after logging.h"
fi

# v0.0.0-alpha macros.h uses HSHM_INLINE; grc-iit/hermes@master uses
# HSHM_ALWAYS_INLINE. Add the alias to macros.h.
_MACROS_H="$INSTALL_ROOT/include/hermes_shm/constants/macros.h"
if ! grep -q 'HSHM_ALWAYS_INLINE' "$_MACROS_H"; then
    printf '\n// Compatibility alias: newer hermes uses HSHM_ALWAYS_INLINE\n#define HSHM_ALWAYS_INLINE HSHM_INLINE\n' \
        >> "$_MACROS_H"
    echo "    Patched macros.h: HSHM_ALWAYS_INLINE -> HSHM_INLINE"
fi

# ---------------------------------------------------------------------------
# 2. Hermes (GRC-IIT version — NOT HDF Group's Hermes)
# ---------------------------------------------------------------------------
if [ ! -f "$INSTALL_ROOT/lib/libhermes.so" ]; then
    echo "==> Cloning Hermes (GRC-IIT)..."
    _clone_if_needed hermes https://github.com/grc-iit/hermes

    cd "$SRC_ROOT/hermes"

    # Patch out REQUIRED on thallium in ALL CMakeLists.txt files in this repo
    # (top-level and subdirs like hrun/) plus the installed HermesShmCommonConfig.cmake.
    # PACE doesn't have Argobots/Mercury/Margo so thallium is unavailable.
    find . -name "CMakeLists.txt" -exec \
        sed -i 's/find_package(thallium CONFIG REQUIRED)/find_package(thallium CONFIG QUIET)/g' {} +
    sed -i 's/find_package(thallium CONFIG REQUIRED)/find_package(thallium CONFIG QUIET)/g' \
        "$INSTALL_ROOT/cmake/HermesShmCommonConfig.cmake"

    # Wipe any stale build dir so cmake re-reads the patched files
    rm -rf build

    # Detect MPI root from the loaded openmpi lmod module or from the wrapper path.
    # Add it to CMAKE_PREFIX_PATH so FindMPI can locate headers and libs.
    _MPI_ROOT=""
    for _var in MPI_HOME OPENMPI_DIR OPENMPI_HOME MPIDIR OMPI_DIR; do
        eval "_val=\${${_var}:-}"
        if [ -n "$_val" ]; then
            _MPI_ROOT="$_val"
            echo "==>   MPI root from \$$_var: $_MPI_ROOT"
            break
        fi
    done
    if [ -z "$_MPI_ROOT" ] && command -v mpicxx &>/dev/null; then
        _MPI_ROOT=$(cd "$(dirname "$(which mpicxx)")/.." && pwd)
        echo "==>   MPI root from mpicxx: $_MPI_ROOT"
    fi
    [ -z "$_MPI_ROOT" ] && echo "WARNING: cannot detect MPI root — hermes_posix may fail" >&2

    # v0.0.0-alpha hermes_shm doesn't export MPI::MPI_CXX transitively (the
    # grc-iit version does).  Inject find_package(MPI) via CMAKE_PROJECT_INCLUDE
    # so it runs right after any project() call before adapter targets are defined.
    _DEPS_INJECT="$SRC_ROOT/hermes/deps_inject.cmake"
    cat > "$_DEPS_INJECT" << 'DEPSEOF'
# v0.0.0-alpha hermes_shm doesn't transitively export MPI or OpenMP targets.
if(NOT TARGET MPI::MPI_CXX)
    find_package(MPI REQUIRED COMPONENTS CXX C)
endif()
if(NOT TARGET OpenMP::OpenMP_CXX)
    find_package(OpenMP REQUIRED COMPONENTS CXX C)
endif()
DEPSEOF

    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_PREFIX_PATH=$INSTALL_ROOT${_MPI_ROOT:+;$_MPI_ROOT}" \
        -DHermesShm_DIR="$INSTALL_ROOT/cmake" \
        -DBOOST_ROOT="$INSTALL_ROOT" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DBUILD_MPI_TESTS=OFF \
        -DBUILD_OpenMP_TESTS=OFF \
        "-DCMAKE_PROJECT_INCLUDE=$_DEPS_INJECT"
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
    echo "==> Building MegaMmap..."
    _clone_if_needed mega_mmap https://github.com/grc-iit/mega_mmap
    cd "$SRC_ROOT/mega_mmap"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$INSTALL_ROOT" \
        -DBUILD_TESTING=OFF
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
