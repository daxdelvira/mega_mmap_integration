"""
plot_results.py — Visualise MegaMmap integration benchmarks.

Reads stats_dict.csv (produced by run_agentic.py / run_noai.py for both
workloads) and produces two figures:

Figure 1 — Original paper-style overview (all mega variants side-by-side)
    Matches Figures 5 and 8 of the MegaMmap paper.

Figure 2 — AtomAgents mega-vs-nomega comparison (grouped bars per mode)
    Each AtomAgents mode (non-agentic, agentic) gets a pair of bars:
      - nomega (control)   vs.  mega (experimental)
    A speedup ratio label floats above each pair.  I/O columns
    (bytes_read_mb, bytes_written_mb) are plotted in additional subplots if
    present in the CSV.

Styling
-------
  - Font   : Times New Roman
  - Palette: Gruvbox dark data colours on white background
    AtomAgents bars → #fe8019 (bright orange)
    DeepDriveMD bars → #83a598 (bright blue/aqua)
  - nomega bars use the base colour at 55% opacity; mega bars are full colour.

Usage
-----
    python analysis/plot_results.py \\
        --csv results/stats_dict.csv \\
        --out analysis/mega_results_20260607.png
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

import matplotlib
import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import pandas as pd

matplotlib.rcParams["font.family"] = "Times New Roman"
matplotlib.rcParams["axes.spines.top"]   = False
matplotlib.rcParams["axes.spines.right"] = False

# ---------------------------------------------------------------------------
# Gruvbox palette
# ---------------------------------------------------------------------------
_ORANGE     = "#fe8019"
_ORANGE_DIM = "#fe80198c"   # 55% opacity hex
_BLUE       = "#83a598"
_BLUE_DIM   = "#83a5988c"

# ---------------------------------------------------------------------------
# Figure 1 — overview (mega-only variants, all four apps × modes)
# ---------------------------------------------------------------------------
_OVERVIEW_VARIANTS = [
    ("AtomAgents",  "agentic-mega", _ORANGE,    "AtomAgents\nagentic"),
    ("AtomAgents",  "noai-mega",    _ORANGE_DIM, "AtomAgents\nnon-agentic"),
    ("DeepDriveMD", "agentic-mega", _BLUE,       "DeepDriveMD\nagentic"),
    ("DeepDriveMD", "noai-mega",    _BLUE_DIM,   "DeepDriveMD\nnon-agentic"),
]

_CORE_METRICS = [
    ("runtime_s",    "Runtime (s)",            "lower is better"),
    ("peak_mem_pct", "Peak DRAM usage (%)",     "lower is better"),
    ("avg_cpu_pct",  "Avg CPU utilisation (%)", "higher = more parallelism"),
]


def _val(df: pd.DataFrame, app: str, variant: str, col: str) -> float:
    rows = df[(df["app"] == app) & (df["variant"] == variant)]
    return float(rows[col].mean()) if not rows.empty else 0.0


def _bar_label(ax, bar, h: float) -> None:
    if h > 0:
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            h * 1.02,
            f"{h:.1f}",
            ha="center", va="bottom",
            fontsize=8, fontfamily="Times New Roman",
        )


def plot_overview(df: pd.DataFrame, out_path: Path) -> None:
    n = len(_CORE_METRICS)
    fig, axes = plt.subplots(1, n, figsize=(5 * n, 5))
    if n == 1:
        axes = [axes]

    x     = np.arange(len(_OVERVIEW_VARIANTS))
    width = 0.55

    for ax, (col, ylabel, note) in zip(axes, _CORE_METRICS):
        heights = [_val(df, app, var, col) for app, var, _, _ in _OVERVIEW_VARIANTS]
        colors  = [c                        for _, _, c, _  in _OVERVIEW_VARIANTS]
        labels  = [lbl                      for _, _, _, lbl in _OVERVIEW_VARIANTS]

        bars = ax.bar(x, heights, width=width, color=colors,
                      edgecolor="black", linewidth=0.7, zorder=3)
        for bar, h in zip(bars, heights):
            _bar_label(ax, bar, h)

        ax.set_xticks(x)
        ax.set_xticklabels(labels, fontsize=9, fontfamily="Times New Roman")
        ax.set_ylabel(ylabel, fontsize=10, fontfamily="Times New Roman")
        ax.tick_params(axis="y", labelsize=8)
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%.1f"))
        ax.set_ylim(bottom=0)
        ax.grid(axis="y", linestyle="--", linewidth=0.5, alpha=0.6, zorder=0)
        ax.set_axisbelow(True)
        ax.set_title(note, fontsize=8, fontfamily="Times New Roman",
                     color="#555555", pad=4)

    fig.suptitle(
        "Vanilla MegaMmap Integration: AtomAgents & DeepDriveMD\n"
        "(agentic vs. non-agentic, window = reported window_size_gb)",
        fontsize=11, fontfamily="Times New Roman", y=1.02,
    )
    legend_handles = [
        mpatches.Patch(facecolor=_ORANGE, edgecolor="black", label="AtomAgents"),
        mpatches.Patch(facecolor=_BLUE,   edgecolor="black", label="DeepDriveMD"),
    ]
    fig.legend(handles=legend_handles, loc="lower center",
               ncol=2, fontsize=9, frameon=False, bbox_to_anchor=(0.5, -0.06))

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"[plot_results] overview → {out_path}")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Figure 2 — AtomAgents mega-vs-nomega comparison
# ---------------------------------------------------------------------------

# Each entry: (mode_label, nomega_variant, mega_variant, base_color)
_AA_MODES = [
    ("Non-agentic\n(LAMMPS)", "noai-nomega",    "noai-mega",    _ORANGE),
    ("Agentic\n(LLM)",        "agentic-nomega",  "agentic-mega", _ORANGE),
]

# Metrics always plotted
_CMP_METRICS = list(_CORE_METRICS)
# I/O metrics added if columns exist
_IO_METRICS = [
    ("bytes_read_mb",    "Disk read (MB)",    "lower = fewer disk fetches"),
    ("bytes_written_mb", "Disk written (MB)", "lower = fewer disk writes"),
]


def _speedup_label(nomega: float, mega: float) -> str:
    """Return '1.23x faster' or '0.87x (slower)' relative to nomega."""
    if nomega <= 0 or mega <= 0:
        return ""
    ratio = nomega / mega  # >1 means mega is faster
    if ratio >= 1:
        return f"{ratio:.2f}x faster"
    return f"{1/ratio:.2f}x slower"


def plot_comparison(df: pd.DataFrame, out_path: Path) -> None:
    has_io = "bytes_read_mb" in df.columns and "bytes_written_mb" in df.columns
    metrics = _CMP_METRICS + (_IO_METRICS if has_io else [])

    n_metrics = len(metrics)
    n_modes   = len(_AA_MODES)
    fig, axes = plt.subplots(1, n_metrics, figsize=(4.5 * n_metrics, 5.5))
    if n_metrics == 1:
        axes = [axes]

    group_w   = 0.6   # total width for the two bars per mode-group
    bar_w     = group_w / 2
    group_gap = 1.0   # spacing between mode groups

    group_centers = np.arange(n_modes) * group_gap
    offsets = np.array([-bar_w / 2, bar_w / 2])

    for ax, (col, ylabel, note) in zip(axes, metrics):
        for gi, (mode_lbl, nomega_var, mega_var, color) in enumerate(
            _AA_MODES
        ):
            nomega_h = _val(df, "AtomAgents", nomega_var, col)
            mega_h   = _val(df, "AtomAgents", mega_var,   col)
            heights  = [nomega_h, mega_h]
            colors   = [color + "8c", color]  # dim for control, full for mega

            xs = group_centers[gi] + offsets
            bars = ax.bar(xs, heights, width=bar_w * 0.9,
                          color=colors, edgecolor="black",
                          linewidth=0.7, zorder=3)
            for bar, h in zip(bars, heights):
                _bar_label(ax, bar, h)

            # Speedup annotation above the pair
            label = _speedup_label(nomega_h, mega_h)
            if label:
                top = max(nomega_h, mega_h)
                ax.text(
                    group_centers[gi], top * 1.10,
                    label,
                    ha="center", va="bottom",
                    fontsize=8, fontfamily="Times New Roman",
                    color="#444444",
                )

        ax.set_xticks(group_centers)
        ax.set_xticklabels(
            [lbl for lbl, _, _, _ in _AA_MODES],
            fontsize=9, fontfamily="Times New Roman",
        )
        ax.set_ylabel(ylabel, fontsize=10, fontfamily="Times New Roman")
        ax.tick_params(axis="y", labelsize=8)
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%.1f"))
        ax.set_ylim(bottom=0)
        ax.grid(axis="y", linestyle="--", linewidth=0.5, alpha=0.6, zorder=0)
        ax.set_axisbelow(True)
        ax.set_title(note, fontsize=8, fontfamily="Times New Roman",
                     color="#555555", pad=4)

    fig.suptitle(
        "AtomAgents: MegaMmap Effect by Mode\n"
        "(dim = no-mega control, solid = mega experimental)",
        fontsize=11, fontfamily="Times New Roman", y=1.02,
    )
    legend_handles = [
        mpatches.Patch(facecolor=_ORANGE + "8c", edgecolor="black",
                       label="no-mega (control)"),
        mpatches.Patch(facecolor=_ORANGE,         edgecolor="black",
                       label="mega (experimental)"),
    ]
    fig.legend(handles=legend_handles, loc="lower center",
               ncol=2, fontsize=9, frameon=False, bbox_to_anchor=(0.5, -0.06))

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"[plot_results] comparison → {out_path}")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _load(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    required = {"app", "variant", "runtime_s", "peak_mem_pct", "avg_cpu_pct"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"stats_dict.csv missing columns: {missing}")
    return df


def main() -> None:
    today = date.today().strftime("%Y%m%d")
    ap = argparse.ArgumentParser(description="Plot MegaMmap integration results")
    ap.add_argument("--csv",  default="results/stats_dict.csv")
    ap.add_argument("--out",  default=f"analysis/mega_results_{today}.png",
                    help="Output path for overview figure")
    ap.add_argument("--out-cmp",
                    default=f"analysis/mega_cmp_atomagents_{today}.png",
                    help="Output path for AtomAgents comparison figure")
    args = ap.parse_args()

    df = _load(Path(args.csv))

    plot_overview(df, Path(args.out))

    aa_variants = {"noai-nomega", "noai-mega", "agentic-nomega", "agentic-mega"}
    if aa_variants & set(df[df["app"] == "AtomAgents"]["variant"].unique()):
        plot_comparison(df, Path(args.out_cmp))
    else:
        print("[plot_results] no AtomAgents nomega rows yet — skipping comparison figure")


if __name__ == "__main__":
    main()
