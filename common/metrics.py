"""
Lightweight pymonitor-equivalent.

Samples RSS and CPU at 1-second intervals while the workload runs, then writes
a stats_dict.csv row matching the schema used in the MegaMmap paper evaluations:
    app, variant, nprocs, window_size_gb, runtime_s, peak_mem_pct, avg_cpu_pct
"""
from __future__ import annotations

import csv
import threading
import time
from pathlib import Path

import psutil


class MetricsCollector:
    """Start before the workload, stop after."""

    def __init__(self) -> None:
        self._running = False
        self._samples: list[dict] = []
        self._thread: threading.Thread | None = None
        self.elapsed_s: float = 0.0
        self._t0: float = 0.0

    # ------------------------------------------------------------------
    def start(self) -> None:
        self._running = True
        self._t0 = time.perf_counter()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        if self._thread:
            self._thread.join(timeout=5)
        self.elapsed_s = time.perf_counter() - self._t0

    def _loop(self) -> None:
        while self._running:
            mem = psutil.virtual_memory()
            cpu = psutil.cpu_percent()
            self._samples.append({"mem_pct": mem.percent, "cpu_pct": cpu})
            time.sleep(1.0)

    # ------------------------------------------------------------------
    @property
    def peak_mem_pct(self) -> float:
        return max((s["mem_pct"] for s in self._samples), default=0.0)

    @property
    def avg_cpu_pct(self) -> float:
        if not self._samples:
            return 0.0
        return sum(s["cpu_pct"] for s in self._samples) / len(self._samples)

    # ------------------------------------------------------------------
    def write_csv(
        self,
        output_path: str | Path,
        *,
        app: str,
        variant: str,
        nprocs: int = 1,
        window_size_gb: float = 0.0,
    ) -> None:
        row = {
            "app": app,
            "variant": variant,
            "nprocs": nprocs,
            "window_size_gb": round(window_size_gb, 3),
            "runtime_s": round(self.elapsed_s, 3),
            "peak_mem_pct": round(self.peak_mem_pct, 2),
            "avg_cpu_pct": round(self.avg_cpu_pct, 2),
        }
        out = Path(output_path)
        write_header = not out.exists()
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(row))
            if write_header:
                writer.writeheader()
            writer.writerow(row)
        print(f"[metrics] {row}")
