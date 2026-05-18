# CMakeLists for the DDMD MegaMmap shims.
#
# Two ways to build:
#
# 1. Drop-in to mega_mmap/benchmark/ and add_subdirectory from there.
#    ${Hermes_LIBRARIES} and include paths are already set by the parent.
#
# 2. Standalone build (set MEGAMMAP_ROOT and HERMES_ROOT via cmake -D):
#
#    cmake -DMEGAMMAP_ROOT=$(spack find --path mega_mmap | tail -1) \
#          -DHERMES_ROOT=$(spack find --path hermes | tail -1) \
#          -S . -B build
#    cmake --build build

cmake_minimum_required(VERSION 3.12)
project(ddmd_mega_shims CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(MPI REQUIRED)

# --- Locate MegaMmap headers ---
if(NOT DEFINED MEGAMMAP_ROOT)
    # Try to infer from the sibling directory in the agent_hpc tree
    get_filename_component(_SHIM_DIR "${CMAKE_CURRENT_SOURCE_DIR}" ABSOLUTE)
    set(MEGAMMAP_ROOT "${_SHIM_DIR}/../../../mega_mmap" CACHE PATH
        "Root of the mega_mmap source tree")
endif()
include_directories("${MEGAMMAP_ROOT}/include")

# --- Locate Hermes ---
if(DEFINED HERMES_ROOT)
    include_directories("${HERMES_ROOT}/include")
    link_directories("${HERMES_ROOT}/lib")
endif()

# When built as part of the mega_mmap tree, ${Hermes_LIBRARIES} is set by
# the parent CMakeLists; otherwise fall back to explicit library names.
if(NOT DEFINED Hermes_LIBRARIES)
    set(Hermes_LIBRARIES hermes hermes_shm_header_only)
endif()

# --- Shim target ---
add_executable(ddmd_contact_map_loader ddmd_contact_map_loader.cc)
target_link_libraries(ddmd_contact_map_loader
    ${Hermes_LIBRARIES}
    MPI::MPI_CXX
)
target_compile_options(ddmd_contact_map_loader PRIVATE -O3)

install(TARGETS ddmd_contact_map_loader RUNTIME DESTINATION bin)
