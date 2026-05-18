"""
mega_patch.py — Injects the MegaMmap contact-map loader into DeepDriveMD apps.

Call install() before importing deepdrivemd workflow modules.  It monkey-patches
CVAETrainApplication and CVAEInferenceApplication so that the
  np.concatenate([np.load(p) for p in paths])
hot-path is replaced by:
  1. npy_to_bin pre-processing (strip numpy headers → raw float32 binary)
  2. mpirun ddmd_contact_map_loader  (MegaMmap tiered I/O)
  3. np.fromfile to return the concatenated array

If the shim binary is not found or fails, falls back to the original numpy path
so normal DDMD runs are unaffected.

Environment variables (all have defaults):
  MEGA_SHIM        path to compiled ddmd_contact_map_loader binary
  MEGA_WINDOW      window size string, e.g. "256m" or "4g"  (default: "256m")
  MEGA_WORKDIR     scratch dir for .bin files                 (default: /tmp/mega_ddmd)
  MEGA_NPROCS      MPI ranks for shim                        (default: 1)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------

_SHIM    = os.environ.get("MEGA_SHIM", "")
_WINDOW  = os.environ.get("MEGA_WINDOW", "256m")
_WORKDIR = Path(os.environ.get("MEGA_WORKDIR", "/tmp/mega_ddmd"))
_NPROCS  = int(os.environ.get("MEGA_NPROCS", "1"))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _npy_to_bin(paths: list[Path], outdir: Path) -> tuple[list[Path], list[list[int]]]:
    """Convert .npy files to raw float32 binary. Returns (bin_paths, shapes)."""
    outdir.mkdir(parents=True, exist_ok=True)
    bin_paths: list[Path] = []
    shapes: list[list[int]] = []
    for p in paths:
        arr = np.load(p, allow_pickle=True)
        arr = np.asarray(arr, dtype=np.float32)
        shapes.append(list(arr.shape))
        dst = outdir / (Path(p).stem + f"_{abs(hash(str(p)))}.bin")
        arr.ravel().tofile(dst)
        bin_paths.append(dst)
    return bin_paths, shapes


def _run_shim(bin_paths: list[Path], shapes: list[list[int]]) -> np.ndarray | None:
    """
    Run ddmd_contact_map_loader, return concatenated float32 array.
    Returns None on failure (caller falls back to numpy).
    """
    if not _SHIM or not Path(_SHIM).exists():
        return None

    _WORKDIR.mkdir(parents=True, exist_ok=True)
    out_bin = _WORKDIR / f"concat_{os.getpid()}.bin"

    cmd = ["mpirun", "-n", str(_NPROCS), _SHIM,
           str(out_bin), _WINDOW] + [str(p) for p in bin_paths]

    t0 = time.perf_counter()
    result = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.perf_counter() - t0

    if result.returncode != 0:
        print(f"[mega_patch] shim failed ({result.returncode}): {result.stderr}",
              file=sys.stderr)
        return None

    # Parse shim CSV output for logging
    for line in result.stdout.splitlines():
        if line and not line.startswith("runtime"):
            shim_rt, n_elems = line.split(",")
            print(f"[mega_patch] shim runtime={float(shim_rt):.3f}s  "
                  f"elements={n_elems}  wall={dt:.3f}s")

    arr = np.fromfile(str(out_bin), dtype=np.float32)
    out_bin.unlink(missing_ok=True)

    # Reconstruct shape: original arrays may be (N, H, W); concatenate on axis 0
    # Each shape[0] is the frame count; remaining dims must match.
    total_frames = sum(s[0] for s in shapes)
    trailing = shapes[0][1:] if len(shapes[0]) > 1 else []
    if trailing:
        arr = arr.reshape(total_frames, *trailing)
    return arr


def _load_contact_maps_mega(paths: list[Path]) -> np.ndarray:
    """
    Drop-in replacement for np.concatenate([np.load(p) for p in paths]).
    Falls back to numpy if MegaMmap shim is unavailable.
    """
    bin_paths, shapes = _npy_to_bin(paths, _WORKDIR / "bins")
    result = _run_shim(bin_paths, shapes)
    if result is not None:
        return result
    # Fallback
    print("[mega_patch] falling back to numpy load", file=sys.stderr)
    return np.concatenate([np.load(p, allow_pickle=True) for p in paths])


# ---------------------------------------------------------------------------
# Monkey-patch
# ---------------------------------------------------------------------------

def install() -> None:
    """Patch CVAETrainApplication and CVAEInferenceApplication."""

    # --- Train ---
    try:
        from deepdrivemd.apps.cvae_train.app import CVAETrainApplication
        import deepdrivemd.apps.cvae_train.app as _train_mod

        _orig_train_run = CVAETrainApplication.run

        def _mega_train_run(self, input_data):
            # Load contact maps via MegaMmap instead of plain np.load
            import numpy as _np
            import pandas as _pd
            import torch as _torch
            from mdlearn.nn.models.vae.symmetric_conv2d_vae import SymmetricConv2dVAETrainer
            from natsort import natsorted
            from deepdrivemd.apps.cvae_train import CVAESettings, CVAETrainOutput
            from deepdrivemd.data_collection.memlogger import logger
            from deepdrivemd.data_collection.phase_timer import PhasePerformanceLogger

            phase_logger = PhasePerformanceLogger(
                workdir=self.workdir, phase_name="cvae_train_mega")
            with phase_logger.measure():
                input_data.dump_yaml(self.workdir / "input.yaml")

                cvae_settings = CVAESettings.from_yaml(
                    self.config.cvae_settings_yaml).dict()
                trainer = SymmetricConv2dVAETrainer(**cvae_settings)

                if self.config.checkpoint_path is not None:
                    checkpoint = _torch.load(
                        self.config.checkpoint_path,
                        map_location=trainer.device)
                    trainer.model.load_state_dict(
                        checkpoint["model_state_dict"])

                # ---- MegaMmap contact map load ----
                contact_maps = _load_contact_maps_mega(
                    [Path(p) for p in input_data.contact_map_paths])
                logger.log(contact_maps, label="train_contact_maps")

                rmsds = _np.concatenate(
                    [_np.load(p) for p in input_data.rmsd_paths])
                logger.log(rmsds, label="train_rmsds")

                model_dir = self.workdir / "model"
                trainer.fit(X=contact_maps,
                            scalars={"rmsd": rmsds},
                            output_path=model_dir)

                _pd.DataFrame(trainer.loss_curve_).to_csv(
                    model_dir / "loss.csv")

                checkpoint_dir = model_dir / "checkpoints"
                model_weight_path = natsorted(
                    list(checkpoint_dir.glob("*.pt")))[-1]
                model_weight_path = (
                    self.persistent_dir / "model" / "checkpoints"
                    / model_weight_path.name)

                output_data = CVAETrainOutput(
                    model_weight_path=model_weight_path)
                output_data.dump_yaml(self.workdir / "output.yaml")
                self.backup_node_local()
                return output_data

        _train_mod.CVAETrainApplication.run = _mega_train_run
        print("[mega_patch] CVAETrainApplication.run patched")
    except ImportError:
        pass

    # --- Inference ---
    try:
        from deepdrivemd.apps.cvae_inference.app import CVAEInferenceApplication
        import deepdrivemd.apps.cvae_inference.app as _infer_mod

        _orig_infer_run = CVAEInferenceApplication.run

        def _mega_infer_run(self, input_data):
            import numpy as _np
            import pandas as _pd
            import torch as _torch
            from sklearn.neighbors import LocalOutlierFactor
            from mdlearn.nn.models.vae.symmetric_conv2d_vae import SymmetricConv2dVAETrainer
            from deepdrivemd.apps.cvae_train import CVAESettings
            from deepdrivemd.apps.cvae_inference import CVAEInferenceOutput
            from deepdrivemd.data_collection.memlogger import logger
            from deepdrivemd.data_collection.phase_timer import PhasePerformanceLogger

            phase_logger = PhasePerformanceLogger(
                workdir=self.workdir, phase_name="cvae_inference_mega")
            with phase_logger.measure():
                input_data.dump_yaml(self.workdir / "input.yaml")

                # ---- MegaMmap contact map load ----
                contact_maps = _load_contact_maps_mega(
                    [Path(p) for p in input_data.contact_map_paths])

                _rmsds = [_np.load(p) for p in input_data.rmsd_paths]
                rmsds = _np.concatenate(_rmsds)
                lengths = [len(d) for d in _rmsds]
                sim_frames = _np.concatenate(
                    [_np.arange(i) for i in lengths])
                sim_dirs = _np.concatenate(
                    [[str(p.parent)] * l
                     for p, l in zip(input_data.rmsd_paths, lengths)])

                cvae_settings = CVAESettings.from_yaml(
                    self.config.cvae_settings_yaml).dict()
                trainer = SymmetricConv2dVAETrainer(**cvae_settings)
                checkpoint = _torch.load(
                    input_data.model_weight_path,
                    map_location=trainer.device)
                trainer.model.load_state_dict(
                    checkpoint["model_state_dict"])

                embeddings, *_ = trainer.predict(
                    X=contact_maps,
                    inference_batch_size=self.config.inference_batch_size)
                logger.log(embeddings, label="inference_embeddings")
                _np.save(self.workdir / "embeddings.npy", embeddings)

                embeddings = _np.nan_to_num(embeddings, nan=0.0)
                clf = LocalOutlierFactor(
                    n_jobs=self.config.sklearn_num_jobs)
                clf.fit(embeddings)
                logger.log(clf.negative_outlier_factor_, label="lof_scores")

                df = (
                    _pd.DataFrame({
                        "rmsd": rmsds,
                        "lof": clf.negative_outlier_factor_,
                        "sim_dirs": sim_dirs,
                        "sim_frames": sim_frames,
                    })
                    .sort_values("lof")
                    .head(self.config.num_outliers)
                )
                if self.config.use_target:
                    df = df.sort_values("rmsd")

                df.to_csv(self.workdir / "outliers.csv")
                return CVAEInferenceOutput(
                    sim_dirs=list(map(Path, df.sim_dirs)),
                    sim_frames=list(df.sim_frames))

        _infer_mod.CVAEInferenceApplication.run = _mega_infer_run
        print("[mega_patch] CVAEInferenceApplication.run patched")
    except ImportError:
        pass
