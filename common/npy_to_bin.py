"""
Convert .npy contact-map files to raw float32 binary so MegaMmap can read them.

MegaMmap's VectorMegaMpi<float> reads plain binary files; numpy .npy files have
a variable-length header that MegaMmap cannot skip.  This one-time preprocessing
step strips headers and writes shape metadata to a companion .meta JSON file so
the Python side can reconstruct the array after MegaMmap produces its output.

Usage
-----
    python npy_to_bin.py --outdir /tmp/mega_ddmd/bins path/to/*.npy
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np


def convert(src: Path, dst_bin: Path) -> dict:
    """Convert one .npy file; return {path, shape, dtype, n_elements}."""
    arr = np.load(src, allow_pickle=True)
    arr = np.asarray(arr, dtype=np.float32)
    arr.ravel().tofile(dst_bin)
    return {
        "src": str(src),
        "bin": str(dst_bin),
        "shape": list(arr.shape),
        "n_elements": int(arr.size),
    }


def convert_many(src_paths: list[Path], outdir: Path) -> list[dict]:
    outdir.mkdir(parents=True, exist_ok=True)
    records = []
    for src in src_paths:
        dst = outdir / (src.stem + ".bin")
        rec = convert(src, dst)
        records.append(rec)
        print(f"  {src.name} → {dst.name}  shape={rec['shape']}")
    manifest = outdir / "manifest.json"
    manifest.write_text(json.dumps(records, indent=2))
    print(f"Manifest: {manifest}")
    return records


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description="Convert .npy → raw float32 for MegaMmap")
    ap.add_argument("inputs", nargs="+", help=".npy files")
    ap.add_argument("--outdir", default="/tmp/mega_ddmd/bins", help="Output directory")
    args = ap.parse_args(argv)
    convert_many([Path(p) for p in args.inputs], Path(args.outdir))


if __name__ == "__main__":
    main()
