"""
plot_results.py — Visualise MegaMmap integration benchmarks.

Reads stats_dict.csv (produced by run_agentic.py / run_noai.py for both
workloads) and produces grouped bar charts matching the style of Figures 5
and 8 of the MegaMmap paper:
  - Runtime (s)
  - Peak DRAM usage (%)
  - Average CPU utilisation (%)

Each metric gets its own subplot within one figure.  Bars are grouped by
app × variant so all four configurations appear side-by-side.

Styling
-------
  - Font   : Times New Roman
  - Palette: Gruvbox dark data colours on white background
    AtomAgents bars  → #fe8019 (bright orange)
    DeepDriveMD bars → #83a598 (bright blue/aqua)
  - Non-agentic variants use the base colour at 55% opacity for visual
    distinction without introducing a new colour.

Usage
-----
    python analysis/plot_results.py \
        --csv results/stats_dict.csv \
        --out analysis/mega_results_20260518.png
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

import matplotlib
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
_ORANGE = "#fe8019"   # AtomAgents
_BLUE   = "#83a598"   # DeepDriveMD

# Variant ordering and display labels
_VARIANTS = [
    ("AtomAgents",  "agentic-mega", _ORANGE,         "AtomAgents\nagentic"),
    ("AtomAgents",  "noai-mega",    _ORANGE + "8c",  "AtomAgents\nnon-agentic"),
    ("DeepDriveMD", "agentic-mega", _BLUE,            "DeepDriveMD\nagentic"),
    ("DeepDriveMD", "noai-mega",    _BLUE   + "8c",  "DeepDriveMD\nnon-agentic"),
]

_METRICS = [
    ("runtime_s",     "Runtime (s)",            "lower is better"),
    ("peak_mem_pct",  "Peak DRAM usage (%)",     "lower is better"),
    ("avg_cpu_pct",   "Avg CPU utilisation (%)", "higher = more parallelism"),
]


def _load(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    required = {"app", "variant", "runtime_s", "peak_mem_pct", "avg_cpu_pct"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"stats_dict.csv missing columns: {missing}")
    return df


def _bar_value(df: pd.DataFrame, app: str, variant: str, metric: str) -> float:
    rows = df[(df["app"] == app) & (df["variant"] == variant)]
    if rows.empty:
        return 0.0
    return float(rows[metric].mean())


def plot(csv_path: Path, out_path: Path) -> None:
    df = _load(csv_path)

    n_metrics = len(_METRICS)
    fig, axes = plt.subplots(1, n_metrics, figsize=(5 * n_metrics, 5))
    if n_metrics == 1:
        axes = [axes]

    x      = np.arange(len(_VARIANTS))
    width  = 0.55

    for ax, (col, ylabel, note) in zip(axes, _METRICS):
        heights = [_bar_value(df, app, var, col) for app, var, _, _ in _VARIANTS]
        colors  = [c                              for _, _, c, _  in _VARIANTS]
        labels  = [lbl                            for _, _, _, lbl in _VARIANTS]

        bars = ax.bar(x, heights, width=width, color=colors,
                      edgecolor="black", linewidth=0.7, zorder=3)

        for bar, h in zip(bars, heights):
            if h > 0:
                ax.text(
                    bar.get_x() + bar.get_width() / 2,
                    h * 1.02,
                    f"{h:.1f}",
                    ha="center", va="bottom",
                    fontsize=8,
                    fontfamily="Times New Roman",
                )

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
        fontsize=11,
        fontfamily="Times New Roman",
        y=1.02,
    )

    # Legend patches
    import matplotlib.patches as mpatches
    legend_handles = [
        mpatches.Patch(facecolor=_ORANGE, edgecolor="black", label="AtomAgents"),
        mpatches.Patch(facecolor=_BLUE,   edgecolor="black", label="DeepDriveMD"),
    ]
    fig.legend(handles=legend_handles, loc="lower center",
               ncol=2, fontsize=9, frameon=False,
               bbox_to_anchor=(0.5, -0.06))

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"[plot_results] saved → {out_path}")
    plt.close(fig)


def main() -> None:
    today = date.today().strftime("%Y%m%d")
    ap = argparse.ArgumentParser(description="Plot MegaMmap integration results")
    ap.add_argument("--csv",
                    default="results/stats_dict.csv",
                    help="Path to stats_dict.csv")
    ap.add_argument("--out",
                    default=f"analysis/mega_results_{today}.png",
                    help="Output PNG path")
    args = ap.parse_args()
    plot(Path(args.csv), Path(args.out))


if __name__ == "__main__":
    main()
