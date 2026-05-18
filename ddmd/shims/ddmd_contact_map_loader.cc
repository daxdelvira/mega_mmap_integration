/**
 * ddmd_contact_map_loader.cc
 *
 * Vanilla MegaMmap shim for DeepDriveMD contact-map loading.
 *
 * Reads a list of raw float32 binary files (numpy headers stripped by
 * npy_to_bin.py) through MegaMmap's SeqTxBegin / tiered DRAM-NVMe storage,
 * concatenates them, and writes the result to a single output binary file that
 * Python reads back with np.fromfile().
 *
 * The key benefit: each input file is accessed with a bounded DRAM window
 * (window_size), so total peak DRAM = window_size rather than the full dataset.
 *
 * Usage (single-process, which covers both agentic and non-agentic DDMD):
 *   mpirun -n 1 ./ddmd_contact_map_loader \
 *       <output.bin> <window_size> <in1.bin> [<in2.bin> ...]
 *
 *   window_size: e.g. "256m", "4g"  (parsed by hshm::ConfigParse::ParseSize)
 *
 * Stdout (CSV, captured by Python wrapper):
 *   runtime_s,elements_read
 *   3.142,12345678
 */

#include <mpi.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include <algorithm>

#include "hermes_shm/util/config_parse.h"
#include "mega_mmap/vector_mega_mpi.h"

namespace stdfs = std::filesystem;

using FloatVec = mm::VectorMegaMpi<float, false>;

// Chunk size for streaming writes to the output file (limits extra DRAM use)
static constexpr size_t WRITE_CHUNK = 1 << 20;  // 1 M floats = 4 MB

int main(int argc, char **argv) {
    MPI_Init(&argc, &argv);
    TRANSPARENT_HERMES();

    int rank, nprocs;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    if (argc < 4) {
        if (rank == 0)
            fprintf(stderr,
                "Usage: %s <output.bin> <window_size> <in1.bin> ...\n",
                argv[0]);
        MPI_Finalize();
        return 1;
    }

    const std::string out_path  = argv[1];
    const size_t      win_bytes = hshm::ConfigParse::ParseSize(argv[2]);

    std::vector<std::string> in_paths;
    for (int i = 3; i < argc; ++i)
        in_paths.push_back(argv[i]);

    // -----------------------------------------------------------------------
    // Measure total elements
    // -----------------------------------------------------------------------
    std::vector<size_t> counts;
    size_t total = 0;
    for (auto &p : in_paths) {
        size_t n = stdfs::file_size(p) / sizeof(float);
        counts.push_back(n);
        total += n;
    }

    // -----------------------------------------------------------------------
    // Open output file for streaming writes
    // -----------------------------------------------------------------------
    FILE *outf = nullptr;
    if (rank == 0) {
        outf = fopen(out_path.c_str(), "wb");
        if (!outf) {
            fprintf(stderr, "Cannot open output: %s\n", out_path.c_str());
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    std::vector<float> chunk_buf(WRITE_CHUNK);

    // -----------------------------------------------------------------------
    // Read each input through MegaMmap, stream to output
    // -----------------------------------------------------------------------
    auto t0 = std::chrono::steady_clock::now();

    for (size_t fi = 0; fi < in_paths.size(); ++fi) {
        const size_t n = counts[fi];

        FloatVec in;
        in.Init(in_paths[fi], MM_READ_ONLY | MM_STAGE);
        in.BoundMemory(win_bytes);
        in.EvenPgas(rank, nprocs, n);
        in.Allocate();

        in.SeqTxBegin(in.local_off(), in.local_size(), MM_READ_ONLY);

        size_t remaining = n;
        size_t elem_off  = 0;
        while (remaining > 0) {
            size_t batch = std::min(remaining, WRITE_CHUNK);
            for (size_t j = 0; j < batch; ++j)
                chunk_buf[j] = in[elem_off + j];
            if (rank == 0)
                fwrite(chunk_buf.data(), sizeof(float), batch, outf);
            elem_off  += batch;
            remaining -= batch;
        }

        in.TxEnd();
        in.Destroy();
    }

    auto t1 = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(t1 - t0).count();

    if (rank == 0) {
        fclose(outf);
        printf("runtime_s,elements_read\n%.6f,%zu\n", elapsed, total);
        fflush(stdout);
    }

    MPI_Barrier(MPI_COMM_WORLD);
    MPI_Finalize();
    return 0;
}
