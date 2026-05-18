"""
run_agentic.py — DeepDriveMD (agentic / openmm_cvae) with vanilla MegaMmap.

Wraps the existing openmm_cvae workflow with:
  1. MegaMmap contact-map patch (mega_patch.install())
  2. MetricsCollector (runtime, peak DRAM, avg CPU)
  3. stats_dict.csv output (same schema as the MegaMmap paper)

Usage
-----
    # Minimum — uses default window size (256 MB) and no shim path yet:
    python run_agentic.py -c /path/to/experiment.yaml

    # With MegaMmap shim:
    MEGA_SHIM=/path/to/ddmd_contact_map_loader \
    MEGA_WINDOW=4g \
    MEGA_WORKDIR=/tmp/mega_ddmd \
    python run_agentic.py -c /path/to/experiment.yaml \
        --stats-csv results/stats_dict.csv

Flags
-----
    -c / --config       DDMD experiment YAML (required)
    --stats-csv         where to append stats_dict row (default: stats_dict.csv)
    --window-gb         window size in GB for the CSV record (default: inferred from MEGA_WINDOW)
    --nprocs            number of parallel workers (default: 1)
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Ensure project root is importable
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent.parent))  # agent_hpc root
sys.path.insert(0, str(_HERE.parent))          # mega_mmap_integration root

# Install MegaMmap patch BEFORE any deepdrivemd imports
from ddmd.mega_patch import install as _install_patch
_install_patch()

from common.metrics import MetricsCollector


def _parse_window_gb(window_str: str) -> float:
    s = window_str.strip().lower()
    if s.endswith("g"):
        return float(s[:-1])
    if s.endswith("m"):
        return float(s[:-1]) / 1024
    if s.endswith("k"):
        return float(s[:-1]) / (1024 ** 2)
    return float(s) / (1024 ** 3)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="DeepDriveMD agentic + vanilla MegaMmap")
    ap.add_argument("-c", "--config", required=True,
                    help="DDMD experiment YAML")
    ap.add_argument("--stats-csv", default="stats_dict.csv",
                    help="Append stats row here")
    ap.add_argument("--window-gb", type=float, default=None,
                    help="DRAM window in GB (default: parse MEGA_WINDOW env var)")
    ap.add_argument("--nprocs", type=int, default=1,
                    help="Parallel workers")
    args = ap.parse_args()

    window_gb = args.window_gb or _parse_window_gb(
        os.environ.get("MEGA_WINDOW", "256m"))

    # -----------------------------------------------------------------------
    # Import and configure DDMD workflow (patch already installed above)
    # -----------------------------------------------------------------------
    from functools import partial, update_wrapper
    from proxystore.store import register_store
    from proxystore.store.file import FileStore
    from colmena.queue.python import PipeQueues
    from colmena.task_server import ParslTaskServer

    from deepdrivemd.api import SimulationCountDoneCallback, TimeoutDoneCallback
    from deepdrivemd.workflows.openmm_cvae import (
        ExperimentSettings,
        DeepDriveMD_OpenMM_CVAE,
        run_simulation,
        run_train,
        run_inference,
    )

    cfg = ExperimentSettings.from_yaml(args.config)
    cfg.dump_yaml(cfg.run_dir / "params.yaml")
    cfg.configure_logging()

    store = FileStore(name="file",
                      store_dir=str(cfg.run_dir / "proxy-store"))
    register_store(store)

    queues = PipeQueues(
        serialization_method="pickle",
        topics=["simulation", "train", "inference"],
        proxystore_name="file",
        proxystore_threshold=10000,
    )

    parsl_config = cfg.compute_settings.config_factory(
        cfg.run_dir / "run-info")

    my_run_simulation = partial(run_simulation,
                                config=cfg.simulation_settings)
    my_run_train      = partial(run_train,
                                config=cfg.train_settings)
    my_run_inference  = partial(run_inference,
                                config=cfg.inference_settings)
    update_wrapper(my_run_simulation, run_simulation)
    update_wrapper(my_run_train,      run_train)
    update_wrapper(my_run_inference,  run_inference)

    doer = ParslTaskServer(
        [my_run_simulation, my_run_train, my_run_inference],
        queues, parsl_config)

    thinker = DeepDriveMD_OpenMM_CVAE(
        queue=queues,
        result_dir=cfg.run_dir / "result",
        simulation_input_dir=cfg.simulation_input_dir,
        num_workers=cfg.num_workers,
        simulations_per_train=cfg.simulations_per_train,
        simulations_per_inference=cfg.simulations_per_inference,
        done_callbacks=[
            SimulationCountDoneCallback(cfg.num_total_simulations),
            TimeoutDoneCallback(cfg.duration_sec),
        ],
    )

    # -----------------------------------------------------------------------
    # Run with metrics
    # -----------------------------------------------------------------------
    mc = MetricsCollector()
    mc.start()
    try:
        doer.start()
        thinker.start()
        thinker.join()
    finally:
        queues.send_kill_signal()
        doer.join()
        store.close()
        mc.stop()

    mc.write_csv(
        args.stats_csv,
        app="DeepDriveMD",
        variant="agentic-mega",
        nprocs=args.nprocs,
        window_size_gb=window_gb,
    )


if __name__ == "__main__":
    main()
