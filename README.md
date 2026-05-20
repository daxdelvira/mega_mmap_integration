# mega_mmap_integration

Integrates **vanilla MegaMmap** tiered I/O into two HPC workloads —
**DeepDriveMD** and **AtomAgents** — and provides scripts to benchmark and
plot results.

MegaMmap streams large datasets through a bounded DRAM window backed by an
NVMe tier, so peak DRAM usage stays at `window_size` regardless of total
dataset size. This repo wires that capability into both workloads without
modifying their upstream source trees.

---

## Repository layout

```
mega_mmap_integration/
├── ddmd/
│   ├── mega_patch.py             # monkey-patch for CVAETrainApplication / CVAEInferenceApplication
│   ├── run_agentic.py            # CVAE-steered (openmm_cvae) workflow launcher
│   ├── run_noai.py               # simulation-only (openmm_noai) workflow launcher
│   └── shims/
│       ├── ddmd_contact_map_loader.cc   # C++/MPI shim — reads .bin files via MegaMmap
│       └── CMakeLists.txt
│
├── atomagents_exp2/
│   ├── run_agentic.py            # LLM-steered (observe_only) launcher via Hermes LD_PRELOAD
│   └── run_noai.py               # baseline LAMMPS launcher via Hermes LD_PRELOAD
│
├── common/
│   ├── metrics.py                # MetricsCollector — samples RSS & CPU, writes stats_dict.csv
│   └── npy_to_bin.py             # standalone .npy → raw float32 converter
│
├── pipelines/                    # Jarvis-style YAML pipelines
│   ├── ddmd_agentic_mega.yaml
│   ├── ddmd_noai_mega.yaml
│   ├── atomagents_agentic_mega.yaml
│   └── atomagents_noai_mega.yaml
│
├── analysis/
│   └── plot_results.py           # grouped bar charts from stats_dict.csv
│
└── scripts/
    ├── blackwell_hold.sh         # SLURM allocation hold (primary)
    └── blackwell_hold_2.sh       # SLURM allocation hold (secondary, isolated log dir)
```

---

## How it works

### DeepDriveMD — Python monkey-patch + C++ shim

DeepDriveMD's CVAE train and inference apps load all contact-map files with:

```python
np.concatenate([np.load(p) for p in paths])  # loads full dataset into DRAM
```

`mega_patch.install()` replaces this at runtime with a three-step pipeline:

1. **npy_to_bin** — strips numpy headers, writes raw `float32` binary files
2. **`mpirun ddmd_contact_map_loader`** — C++ shim reads each binary through
   `VectorMegaMpi` with a bounded DRAM window and concatenates to one output file
3. **`np.fromfile`** — Python reads the output binary back as a numpy array

If the shim binary is missing or fails, the patch falls back to the original
numpy path transparently.

### AtomAgents — Hermes transparent POSIX interception

AtomAgents' dominant I/O is loading LLM model weights via `transformers`.
There is no single numpy hotspot to patch, so Hermes' POSIX interceptor
(`libhermes_posix.so`) is injected via `LD_PRELOAD`, routing all `mmap`/`read`
calls through MegaMmap's buffer pool without any source changes.

Because `LD_PRELOAD` must be set before the dynamic linker runs, the launchers
re-exec `cluster_atomagents_exp2.py` as a subprocess with the correct
environment already in place.

---

## Prerequisites

| Dependency | Notes |
|---|---|
| [MegaMmap](https://github.com/grc-iit/mega_mmap) | `VectorMegaMpi` headers + Hermes |
| [Hermes](https://github.com/HDFGroup/hermes) | daemon + `libhermes_posix.so` |
| DeepDriveMD | upstream DDMD pipeline |
| AtomAgents (`cluster_atomagents_exp2.py`) | upstream AtomAgents runtime |
| MPI (e.g. OpenMPI) | for the DDMD shim |
| Python >= 3.9, `psutil`, `numpy`, `matplotlib`, `pandas` | Python deps |

Set `AGENT_HPC_ROOT` to the root of the `agent_hpc` repository before using
any pipeline or launcher:

```bash
export AGENT_HPC_ROOT=/path/to/agent_hpc
```

---

## Building the DDMD shim

**Standalone build:**

```bash
cd ddmd/shims
cmake -DMEGAMMAP_ROOT=$(spack find --path mega_mmap | tail -1) \
      -DHERMES_ROOT=$(spack find --path hermes | tail -1) \
      -S . -B build
cmake --build build
```

**Sub-tree build:** drop `shims/` into `mega_mmap/benchmark/` and add via
`add_subdirectory`; CMake variables are inherited from the parent.

The binary lands at `ddmd/shims/build/ddmd_contact_map_loader`.

---

## Running

### Via Jarvis pipelines (recommended)

Edit the `params` block in the relevant YAML, then:

```bash
jarvis pipeline run pipelines/ddmd_agentic_mega.yaml
```

Key parameters:

| Parameter | Default | Description |
|---|---|---|
| `window_size` | `256m` | DRAM buffer window (e.g. `256m`, `4g`) |
| `nprocs` | `1` | MPI ranks for the DDMD shim |
| `config` | *(required)* | Path to DDMD `ExperimentSettings` YAML |
| `stats_csv` | `results/stats_dict.csv` | Output metrics file |

For AtomAgents pipelines set `HERMES_ROOT` in your environment; the pipeline
infers `libhermes_posix.so` from it.

### Direct Python launchers

**DeepDriveMD agentic:**

```bash
MEGA_SHIM=$AGENT_HPC_ROOT/mega_mmap_integration/ddmd/shims/build/ddmd_contact_map_loader \
MEGA_WINDOW=4g \
MEGA_WORKDIR=/tmp/mega_ddmd \
python ddmd/run_agentic.py \
    --config /path/to/experiment.yaml \
    --stats-csv results/stats_dict.csv
```

**AtomAgents agentic:**

```bash
HERMES_INTERCEPTOR=$HERMES_ROOT/lib/libhermes_posix.so \
MEGA_WINDOW=4g \
python atomagents_exp2/run_agentic.py \
    --stats-csv results/stats_dict.csv \
    -- --hw-profile l40s
```

Arguments after `--` are forwarded to `cluster_atomagents_exp2.py`. Omitting
`HERMES_INTERCEPTOR` runs the workload without MegaMmap buffering (metrics
only, useful as a baseline).

### Preprocessing contact maps manually

```bash
python common/npy_to_bin.py --outdir /tmp/bins path/to/*.npy
```

---

## Output and analysis

Each launcher appends one row to `stats_dict.csv`:

```
app,variant,nprocs,window_size_gb,runtime_s,peak_mem_pct,avg_cpu_pct
DeepDriveMD,agentic-mega,1,4.0,312.5,42.1,67.3
```

Once you have rows for all four variants, generate the comparison figure:

```bash
python analysis/plot_results.py \
    --csv results/stats_dict.csv \
    --out analysis/mega_results.png
```

Produces a grouped bar chart comparing runtime, peak DRAM %, and avg CPU %
across all four configurations (Gruvbox palette, Times New Roman), matching
the style of the MegaMmap paper evaluation figures.

---

## Environment variables

| Variable | Used by | Default | Description |
|---|---|---|---|
| `MEGA_SHIM` | DDMD patch | *(empty)* | Path to `ddmd_contact_map_loader` binary |
| `MEGA_WINDOW` | both | `256m` | DRAM buffer window size |
| `MEGA_WORKDIR` | DDMD | `/tmp/mega_ddmd` | Scratch dir for `.bin` files |
| `MEGA_NPROCS` | DDMD patch | `1` | MPI ranks for the shim |
| `HERMES_INTERCEPTOR` | AtomAgents | *(empty)* | Path to `libhermes_posix.so` |
| `HERMES_CONF` | AtomAgents | *(auto-generated)* | Path to `hermes.yaml` |
| `AGENT_HPC_ROOT` | pipelines | *(required)* | Root of the `agent_hpc` repo |
