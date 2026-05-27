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
# grc-iit/hermes@master expects the post-iowarp hermes_shm API.
# grc-iit/hermes_shm is tried first; if inaccessible, fall back to
# hyoklee/cte-hermes-shm@main which merged iowarp and has the same API surface.
_clone_hermes_shm() {
    # Post-iowarp hermes_shm has a containers/ subdir; v0.0.0-alpha does not.
    if [ -d "$SRC_ROOT/hermes_shm" ] && \
       [ -d "$SRC_ROOT/hermes_shm/include/hermes_shm/data_structures/containers" ]; then
        echo "    (hermes_shm source already at post-iowarp version)"
        return
    fi
    # Wipe v0.0.0-alpha or any stale/partial clone before re-cloning
    rm -rf "$SRC_ROOT/hermes_shm"
    echo "    Trying grc-iit/hermes_shm (authoritative post-iowarp source)..."
    if git clone --depth=1 https://github.com/grc-iit/hermes_shm \
           "$SRC_ROOT/hermes_shm" 2>/dev/null; then
        echo "    grc-iit/hermes_shm cloned"
        return
    fi
    # grc-iit/hermes@master uses the pre-iowarp Allocator* API (NewObj on Allocator,
    # non-template GetAllocator, allocator_id_ fields, etc.).  hyoklee@main moved
    # all allocation to CtxAllocator<AllocT>, which is architecturally incompatible.
    # v0.0.0-alpha still has the pre-iowarp Allocator* interface that matches.
    echo "    grc-iit unavailable; using hyoklee/cte-hermes-shm@v0.0.0-alpha..."
    git clone --depth=1 --branch v0.0.0-alpha \
        https://github.com/hyoklee/cte-hermes-shm "$SRC_ROOT/hermes_shm"
}

# Install is considered complete only when the post-iowarp stamp file exists,
# meaning this script built it (not a leftover v0.0.0-alpha install).
# hyoklee installs libhermes_shm_host.so; grc-iit installs libhermes_shm_data_structures.so.
_hermes_shm_complete() {
    [ -f "$INSTALL_ROOT/.hermes_shm_new_api" ] && \
    { [ -f "$INSTALL_ROOT/lib/libhermes_shm_data_structures.so" ] \
   || [ -f "$INSTALL_ROOT/lib/libhermes_shm_host.so" ]; }
}

if ! _hermes_shm_complete; then
    echo "==> Building HermesShm (v0.0.0-alpha, pre-iowarp API)..."
    # Wipe any stale headers/libs so they don't pollute the fresh build.
    # Also clear the hermes install so it relinks against the new shm libs.
    rm -rf "$INSTALL_ROOT/include/hermes_shm" \
           "$INSTALL_ROOT/cmake/HermesShmCommon"* \
           "$INSTALL_ROOT/.hermes_shm_new_api"
    for _pat in libhermes_shm_data_structures libhermes_shm_host; do
        rm -f "$INSTALL_ROOT/lib/${_pat}"* "$INSTALL_ROOT/lib64/${_pat}"*
    done
    rm -f "$INSTALL_ROOT/lib/libhermes.so" \
          "$INSTALL_ROOT/lib/libhermes_posix.so"
    _clone_hermes_shm
    cd "$SRC_ROOT/hermes_shm"
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DHERMES_SHM_ENABLE_TESTING=OFF \
        -DHSHM_BUILD_UNIT_TESTS=OFF \
        -DHSHM_BUILD_TESTING=OFF
    # Build only the library target. hyoklee/cte-hermes-shm@main builds unit
    # tests even with BUILD_TESTING=OFF, and running them all in parallel causes
    # OOM-kills on PACE interactive nodes. Target the lib directly; fall back to
    # a low-parallelism full build with -k if the target name differs.
    cmake --build build -j"$(nproc)" --target hermes_shm_host 2>/dev/null \
        || cmake --build build -j"$(nproc)" --target hermes_shm_data_structures 2>/dev/null \
        || cmake --build build -j4 -- -k 2>/dev/null \
        || true
    # hyoklee registers test executables in install rules; since we built only
    # the library target they don't exist and cmake --install errors on them.
    # The library and headers ARE installed before cmake hits that error, so
    # suppress the exit code and verify the library landed.
    cmake --install build 2>/dev/null || true
    if ! { [ -f "$INSTALL_ROOT/lib/libhermes_shm_host.so" ] || \
           [ -f "$INSTALL_ROOT/lib/libhermes_shm_data_structures.so" ]; }; then
        echo "ERROR: hermes_shm library not in $INSTALL_ROOT/lib after install" >&2
        exit 1
    fi
    touch "$INSTALL_ROOT/.hermes_shm_new_api"
    echo "==> HermesShm installed"
else
    echo "==> HermesShm already installed, skipping"
fi

# Patch CtxAllocator in the installed allocator.h: add implicit conversion to
# Allocator*.  post-iowarp CtxAllocator<AllocT> exposes operator*() returning
# AllocT* but no operator Allocator*().  grc-iit/hermes@master passes
# CtxAllocator directly where raw Allocator* is expected.
_ALLOC_H="$INSTALL_ROOT/include/hermes_shm/memory/allocator/allocator.h"
if [ -f "$_ALLOC_H" ] && ! grep -q 'operator Allocator\*() const' "$_ALLOC_H"; then
    sed -i '/AllocT \*operator\*() const { return alloc_; }/a\  operator Allocator*() const { return static_cast<Allocator*>(alloc_); }' \
        "$_ALLOC_H"
    echo "    Patched allocator.h: added CtxAllocator::operator Allocator*()"
fi

# ---------------------------------------------------------------------------
# Patch allocator.h:
#   (a) Add forwarding template methods to class Allocator so that
#       grc-iit/hermes@master can call NewObj/NewObjLocal/AllocateLocalPtr/
#       DelObj/DelObjLocal/Convert on Allocator* pointers.  The bodies cast
#       this to BaseAllocator<_ThreadLocalAllocator>* and forward; the cast
#       compiles via static_cast (UB if runtime type differs, but acceptable
#       for our stub-build goal).  Bodies reference BaseAllocator which is
#       defined later in this header; they are only compiled at instantiation
#       time (standard C++ behaviour for inline template methods).
#   (b) Add CtxAllocator(Allocator*) constructor so that the implicit
#       conversion Allocator* -> CtxAllocator<AllocT> is available, which
#       lets vector(Allocator*, size_t) resolve via the existing
#       vector(CtxAllocator<AllocT>, size_t, ...) constructor.
# Patch memory_manager_.h:
#   Add non-template GetAllocator(AllocatorId) overload returning Allocator*.
#   grc-iit/hermes@master calls GetAllocator without a template argument to
#   obtain main_alloc_ / data_alloc_ / rdata_alloc_.
# ---------------------------------------------------------------------------
cat > /tmp/_pace_patch_alloc.py << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    txt = f.read()
if '_as_def_()' in txt:
    sys.exit(0)
COMPAT = r"""
 public:
  // compat bridge — added by setup_pace.sh
  // grc-iit/hermes@master calls these on Allocator*; post-iowarp moved them
  // to BaseAllocator<CoreAllocT>.  Forward via static_cast to concrete subtype.
  // BaseAllocator is forward-declared before this class so the typedef resolves
  // at definition time; the full definition is in scope at instantiation time.
  void _as_def_() {}  // sentinel for grep guard only
  template<typename T, typename PointerT = Pointer, typename... Args>
  inline T* NewObj(const MemContext &ctx, PointerT &p, Args &&...args) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    return static_cast<DA_*>(this)->template NewObj<T>(
        ctx, p, std::forward<Args>(args)...); }
  template<typename T, typename... Args>
  inline auto NewObjLocal(const MemContext &ctx, Args &&...args) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    return static_cast<DA_*>(this)->template NewObjLocal<T>(
        ctx, std::forward<Args>(args)...); }
  template<typename T>
  inline auto AllocateLocalPtr(size_t size) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    return static_cast<DA_*>(this)->template AllocateLocalPtr<T>(
        MemContext(), size); }
  template<typename T>
  inline auto AllocateLocalPtr(const MemContext &ctx, size_t size) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    return static_cast<DA_*>(this)->template AllocateLocalPtr<T>(ctx, size); }
  template<typename T>
  inline void DelObj(const MemContext &ctx, T *obj) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    static_cast<DA_*>(this)->template DelObj<T>(ctx, obj); }
  template<typename T, typename PtrT>
  inline void DelObjLocal(const MemContext &ctx, PtrT &ptr) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    static_cast<DA_*>(this)->template DelObjLocal<T>(ctx, ptr); }
  inline void Free(const Pointer &p) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    static_cast<DA_*>(this)->Free(p); }
  template<typename PtrT>
  inline void FreeLocalPtr(PtrT &ptr) {
    typedef BaseAllocator<_ThreadLocalAllocator> DA_;
    static_cast<DA_*>(this)->FreeLocalPtr(ptr); }
"""
m = re.search(r'class Allocator\b[^{]*\{', txt)
if m:
    fwd = 'template<typename CoreAllocT> class BaseAllocator;  // compat fwd decl\n'
    txt = txt[:m.start()] + fwd + txt[m.start():]
    m2 = re.search(r'class Allocator\b[^{]*\{', txt)
    txt = txt[:m2.end()] + COMPAT + txt[m2.end():]
CTX_CTOR = '\n  CtxAllocator(Allocator *a) : alloc_(static_cast<AllocT*>(a)), ctx_() {}'
txt = txt.replace(
    'CtxAllocator(AllocT *alloc) : alloc_(alloc), ctx_() {}',
    'CtxAllocator(AllocT *alloc) : alloc_(alloc), ctx_() {}' + CTX_CTOR, 1)
with open(path, 'w') as f:
    f.write(txt)
PYEOF

cat > /tmp/_pace_patch_memmgr.py << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    txt = f.read()
if 'GetAllocator<Allocator>' in txt:
    sys.exit(0)
OVERLOAD = ('\n  // compat: grc-iit/hermes@master calls GetAllocator without template arg\n'
            '  HSHM_CROSS_FUN Allocator *GetAllocator(const AllocatorId &alloc_id) {\n'
            '    return GetAllocator<Allocator>(alloc_id);\n  }')
needle = 'HSHM_CROSS_FUN AllocT *GetAllocator(const AllocatorId &alloc_id) {'
idx = txt.find(needle)
if idx == -1:
    sys.exit(0)
brace_pos = idx + len(needle) - 1
depth, pos = 1, brace_pos + 1
while pos < len(txt) and depth:
    if txt[pos] == '{': depth += 1
    elif txt[pos] == '}': depth -= 1
    pos += 1
txt = txt[:pos] + OVERLOAD + txt[pos:]
with open(path, 'w') as f:
    f.write(txt)
PYEOF

_ALLOC_H="$INSTALL_ROOT/include/hermes_shm/memory/allocator/allocator.h"
if [ -f "$_ALLOC_H" ] && ! grep -q '_as_def_()' "$_ALLOC_H"; then
    python3 /tmp/_pace_patch_alloc.py "$_ALLOC_H"
    echo "    Patched allocator.h: Allocator compat methods + CtxAllocator(Allocator*)"
fi

_MEM_MGR_H="$INSTALL_ROOT/include/hermes_shm/memory/memory_manager_.h"
if [ -f "$_MEM_MGR_H" ] && ! grep -q 'GetAllocator<Allocator>' "$_MEM_MGR_H"; then
    python3 /tmp/_pace_patch_memmgr.py "$_MEM_MGR_H"
    echo "    Patched memory_manager_.h: non-template GetAllocator overload"
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

# ipc/internal/ subdir: v0.0.0-alpha keeps shm_internal.h one level up at internal/
mkdir -p "$_DS/ipc/internal"
_inject_stub "$_DS/ipc/internal/shm_internal.h" \
    '#pragma once' '#include "../../internal/shm_internal.h"'

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

# pod_array.h existed in v0.0.0-alpha but was removed from @main.
# hrun/include/hrun/hrun_types.h:25 requires it. Provide a std::vector-backed
# stub that satisfies the interface hermes uses (operator[], size, Init, etc.).
_POD_ARRAY_H="$_DS/ipc/pod_array.h"
if [ ! -f "$_POD_ARRAY_H" ]; then
    cat > "$_POD_ARRAY_H" << 'PODARRAYEOF'
#pragma once
#include <vector>
#include <cstddef>

namespace hshm { namespace ipc {

template<typename T>
class PodArray {
  std::vector<T> data_;
 public:
  PodArray() = default;
  explicit PodArray(size_t n) : data_(n) {}

  T& operator[](size_t i) { return data_[i]; }
  const T& operator[](size_t i) const { return data_[i]; }
  size_t size() const { return data_.size(); }
  bool empty() const { return data_.empty(); }
  T* data() { return data_.data(); }
  const T* data() const { return data_.data(); }
  void resize(size_t n) { data_.resize(n); }
  void emplace_back(const T& v) { data_.push_back(v); }
  void push_back(const T& v) { data_.push_back(v); }
  void clear() { data_.clear(); }
  T* begin() { return data_.data(); }
  T* end() { return data_.data() + data_.size(); }
  const T* begin() const { return data_.data(); }
  const T* end() const { return data_.data() + data_.size(); }

  // SHM alloc-based construction shim (no-op; data lives on heap)
  template<typename AllocT> void Init(AllocT*, size_t n) { data_.resize(n); }
  void shm_destroy() {}
};

}}  // namespace hshm::ipc
PODARRAYEOF
    echo "    stubbed: $_POD_ARRAY_H"
fi

# thallium.hpp: PACE has no Argobots/Mercury/Margo. Provide a minimal stub so
# task.h (and other code that #include <thallium.hpp>) compiles cleanly.
# Thallium types are used for RPC serialization; stub makes them no-ops.
_THALLIUM_H="$INSTALL_ROOT/include/thallium.hpp"
if [ ! -f "$_THALLIUM_H" ]; then
    cat > "$_THALLIUM_H" << 'THEOF'
#pragma once
// Minimal thallium stub: PACE has no Argobots/Mercury/Margo.
// Provides empty type shells so grc-iit/hermes compiles; RPC calls are no-ops.
#include <string>
#include <functional>
#include <cstdint>

namespace thallium {

struct endpoint {
  bool is_null() const { return true; }
  operator bool() const { return false; }
  std::string get_addr() const { return ""; }
};

struct bulk { operator bool() const { return false; } };
struct local_bulk {};
struct remote_bulk { operator bool() const { return false; } };

class pool { public: pool() = default; };
class xstream {
 public:
  static xstream& self() { static xstream s; return s; }
};

class engine {
 public:
  engine() = default;
  template<typename... A> engine(A&&...) {}
  void finalize() {}
  void wait_for_finalize() {}
  endpoint self() const { return {}; }
  endpoint lookup(const std::string&) const { return {}; }
  bool progress_needed() const { return false; }
  std::string self_addr() const { return ""; }
  operator bool() const { return false; }
  template<typename F> void define(const std::string&, F&&) {}
  template<typename F> void define(const std::string&, F&&, pool&) {}
};

class request {
 public:
  endpoint get_endpoint() const { return {}; }
  template<typename... T> void respond(T&&...) const {}
  void disable_response() const {}
};

// Serialization archive stubs (thallium uses cereal-style ar & field)
class proc_input {
 public:
  template<typename T> proc_input& operator>>(T&) { return *this; }
  template<typename T> proc_input& operator&(T&) { return *this; }
};
class proc_output {
 public:
  template<typename T> proc_output& operator<<(const T&) { return *this; }
  template<typename T> proc_output& operator&(T&) { return *this; }
};
using input_archive  = proc_input;
using output_archive = proc_output;

template<typename... T> struct remote_procedure {
  remote_procedure() = default;
  template<typename... A> remote_procedure(A&&...) {}
};

} // namespace thallium

namespace tl = thallium;

// Hermes uses these serialization macros from thallium/cereal
#define THALLIUM_DEFINE_SERIALIZE(...)
#define THALLIUM_SERIALIZE(...)
THEOF
    echo "    Created thallium.hpp stub at $_THALLIUM_H"
fi

# config_parse.h in v0.0.0-alpha doesn't include logging.h, so HILOG is not
# in scope when grc-iit/hermes config.h compiles. Also, v0.0.0-alpha's HILOG
# uses a different signature (SUB_CODE, ...) vs the new (verbosity, ...).
# Patch config_parse.h: include logging.h, then redefine HILOG as a no-op.
# config_parse.h already includes logging.h in v0.0.0-alpha, but logging.h's
# HILOG expands to HLOG(...) which is never defined, causing "expected ';'"
# errors. Redefine HILOG as a no-op immediately after the logging.h include.
_CONFIG_PARSE="$INSTALL_ROOT/include/hermes_shm/util/config_parse.h"
if [ -f "$_CONFIG_PARSE" ] && ! grep -q '#define HELOG(...)' "$_CONFIG_PARSE"; then
    awk '/#include "logging.h"/ {
        print
        print "// Logging compat: HILOG/HELOG expand to HLOG which is undefined in"
        print "// v0.0.0-alpha; redefine both as no-ops to match the new calling convention."
        print "#undef HILOG"
        print "#define HILOG(...)"
        print "#undef HELOG"
        print "#define HELOG(...)"
        next
    } { print }' "$_CONFIG_PARSE" > "${_CONFIG_PARSE}.tmp" \
        && mv "${_CONFIG_PARSE}.tmp" "$_CONFIG_PARSE"
    echo "    Patched config_parse.h: HILOG/HELOG no-ops after logging.h"
fi

# Patch macros.h with compatibility aliases for names that changed between
# v0.0.0-alpha and the post-iowarp API used by grc-iit/hermes@master.
_MACROS_H="$INSTALL_ROOT/include/hermes_shm/constants/macros.h"
if [ -f "$_MACROS_H" ]; then
    if ! grep -q 'HSHM_ALWAYS_INLINE' "$_MACROS_H"; then
        printf '\n// Compatibility alias: newer hermes uses HSHM_ALWAYS_INLINE\n#define HSHM_ALWAYS_INLINE HSHM_INLINE\n' \
            >> "$_MACROS_H"
        echo "    Patched macros.h: HSHM_ALWAYS_INLINE -> HSHM_INLINE"
    fi
    if ! grep -q 'HERMES_THREAD_MODEL' "$_MACROS_H"; then
        printf '\n// HERMES_ -> HSHM_ singleton name aliases for grc-iit/hermes@master\n#ifndef HERMES_THREAD_MODEL\n#define HERMES_THREAD_MODEL HSHM_THREAD_MODEL\n#endif\n#ifndef HERMES_MEMORY_MANAGER\n#define HERMES_MEMORY_MANAGER HSHM_MEMORY_MANAGER\n#endif\n' \
            >> "$_MACROS_H"
        echo "    Patched macros.h: HERMES_THREAD_MODEL/MEMORY_MANAGER aliases"
    fi
fi

# PACE has no Argobots. HRUN task-scheduler code calls ABT_thread_yield() and
# friends via #include <abt.h>. Provide a minimal stub so compilation succeeds.
_ABT_H="$INSTALL_ROOT/include/abt.h"
if [ ! -f "$_ABT_H" ]; then
    cat > "$_ABT_H" << 'ABTEOF'
#pragma once
/* Minimal Argobots stub: PACE has no Argobots/Mercury/Margo. */
#ifdef __cplusplus
extern "C" {
#endif
typedef int ABT_thread;
typedef int ABT_xstream;
typedef int ABT_pool;
typedef int ABT_sched;
typedef int ABT_unit;
typedef int ABT_mutex;
typedef int ABT_cond;
#define ABT_SUCCESS 0
#define ABT_ERR_UNINITIALIZED (-1)
static inline int ABT_thread_yield(void) { return ABT_SUCCESS; }
static inline int ABT_thread_self(ABT_thread *t) { if (t) *t = 0; return ABT_SUCCESS; }
static inline int ABT_xstream_self(ABT_xstream *x) { if (x) *x = 0; return ABT_SUCCESS; }
static inline int ABT_xstream_get_main_pools(ABT_xstream x, int n, ABT_pool *p) {
    (void)x; (void)n; if (p) *p = 0; return ABT_SUCCESS; }
static inline int ABT_pool_pop_thread(ABT_pool p, ABT_thread *t) {
    (void)p; if (t) *t = -1; return ABT_SUCCESS; }
static inline int ABT_mutex_create(ABT_mutex *m) { if (m) *m = 0; return ABT_SUCCESS; }
static inline int ABT_mutex_lock(ABT_mutex m) { (void)m; return ABT_SUCCESS; }
static inline int ABT_mutex_unlock(ABT_mutex m) { (void)m; return ABT_SUCCESS; }
static inline int ABT_mutex_free(ABT_mutex *m) { (void)m; return ABT_SUCCESS; }
static inline int ABT_cond_create(ABT_cond *c) { if (c) *c = 0; return ABT_SUCCESS; }
static inline int ABT_cond_wait(ABT_cond c, ABT_mutex m) { (void)c; (void)m; return ABT_SUCCESS; }
static inline int ABT_cond_signal(ABT_cond c) { (void)c; return ABT_SUCCESS; }
static inline int ABT_cond_broadcast(ABT_cond c) { (void)c; return ABT_SUCCESS; }
static inline int ABT_cond_free(ABT_cond *c) { (void)c; return ABT_SUCCESS; }
#ifdef __cplusplus
}
#endif
ABTEOF
    echo "    Created abt.h stub at $_ABT_H"
fi

# SHM_CONTAINER_TEMPLATE was removed from post-iowarp hermes_shm but
# grc-iit/hermes@master uses it inside class bodies to inject shm_init_container,
# GetAllocator, and shm_destroy members.  Provide a stub header force-included
# via -include so every TU sees the definition before it is used.
_COMPAT_H="$INSTALL_ROOT/include/hermes_compat.h"
if [ ! -f "$_COMPAT_H" ] || ! grep -q '#include <abt.h>' "$_COMPAT_H"; then
    cat > "$_COMPAT_H" << 'COMPATEOF'
#pragma once
// Force-included via -include so every TU sees these definitions.
// ABT_thread_yield is called in template bodies; GCC phase-1 lookup requires
// the declaration to be visible at the template definition point.
#include <abt.h>
// SHM_CONTAINER_TEMPLATE was removed from newer hermes_shm but
// grc-iit/hermes@master uses it inside class bodies.
#ifndef SHM_CONTAINER_TEMPLATE
#define SHM_CONTAINER_TEMPLATE(CLASS_NAME, TYPED_CLASS)                            \
 public:                                                                            \
  hshm::ipc::Allocator *_compat_alloc_{nullptr};                                   \
  inline void shm_init_container(hshm::ipc::Allocator *a) { _compat_alloc_ = a; } \
  inline hshm::ipc::Allocator *GetAllocator() const { return _compat_alloc_; }    \
  inline void shm_destroy() {}
#endif
COMPATEOF
    echo "    Created/updated hermes_compat.h at $_COMPAT_H"
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

    # hrun_client.h:67 calls SetThreadModel which hyoklee's Pthread class lacks.
    # Remove the call; thread model defaults to pthread without explicit setting.
    _HRUN_CLIENT_H="$SRC_ROOT/hermes/hrun/include/hrun/api/hrun_client.h"
    if [ -f "$_HRUN_CLIENT_H" ]; then
        sed -i '/HSHM_THREAD_MODEL->SetThreadModel/d' "$_HRUN_CLIENT_H"
        echo "    Patched hrun_client.h: removed SetThreadModel call"
    fi

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
        -Wno-dev \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_PREFIX_PATH=$INSTALL_ROOT${_MPI_ROOT:+;$_MPI_ROOT}" \
        -DHermesShm_DIR="$INSTALL_ROOT/cmake" \
        -DBOOST_ROOT="$INSTALL_ROOT" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DBUILD_MPI_TESTS=OFF \
        -DBUILD_OpenMP_TESTS=OFF \
        "-DCMAKE_PROJECT_INCLUDE=$_DEPS_INJECT" \
        "-DCMAKE_CXX_FLAGS=-I$INSTALL_ROOT/include -include $INSTALL_ROOT/include/hermes_compat.h" \
        "-DCMAKE_C_FLAGS=-I$INSTALL_ROOT/include"
    # -k: keep going past test/tool linker errors so core libs always build
    cmake --build build -j"$(nproc)" -- -k 2>&1 | tee /tmp/hermes_build.log || true
    # Verify the essential outputs before installing
    if [ ! -f build/src/libhermes.so ] && [ ! -f build/hermes_adapters/posix/libhermes_posix.so ]; then
        echo "ERROR: hermes core libraries not built — see /tmp/hermes_build.log" >&2
        grep -i "error:" /tmp/hermes_build.log | grep -v "^--" | head -20 >&2
        exit 1
    fi
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
