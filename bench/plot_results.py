"""
plot_results.py - Gera os graficos comparativos (PNG) a partir do JSON de resultados.

Mesma fonte de dados do notebook (bench/results/bench_*.json), mas determinístico e
sem precisar de Jupyter. Salva em assets/img/.

Uso:
    python bench/plot_results.py                 # usa o JSON mais recente
    python bench/plot_results.py <arquivo.json>  # usa um especifico
"""

from __future__ import annotations

import glob
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")  # sem display
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "assets", "img")

ENDPOINTS = ["cpu-bound", "io-read", "io-write"]
SCENARIOS = ["fpm", "frankenphp", "swoole"]
LABELS = {"fpm": "PHP-FPM+JIT", "frankenphp": "FrankenPHP", "swoole": "Swoole"}
COLORS = {"fpm": "#4C78A8", "frankenphp": "#54A24B", "swoole": "#E45756"}


def load(path: str | None) -> dict:
    if not path:
        files = sorted(glob.glob(os.path.join(HERE, "results", "bench_*.json")))
        if not files:
            sys.exit("Nenhum bench_*.json em bench/results/ — rode bench/loadtest.py antes.")
        path = files[-1]
    rows = json.load(open(path))
    data = {(r["scenario"], r["endpoint"]): r for r in rows}
    print(f"fonte: {path}")
    return data


def grouped_by_endpoint(data, metric, title, ylabel, fname, fmt):
    """Um subplot por endpoint (escalas independentes — cpu-bound e io-read diferem ~200x)."""
    fig, axes = plt.subplots(1, 3, figsize=(11, 4.2))
    for ax, ep in zip(axes, ENDPOINTS):
        vals = [data[(sc, ep)][metric] for sc in SCENARIOS]
        bars = ax.bar(
            [LABELS[s] for s in SCENARIOS], vals,
            color=[COLORS[s] for s in SCENARIOS],
        )
        ax.set_title(f"/bench/{ep}", fontsize=11)
        ax.bar_label(bars, fmt=fmt, fontsize=8, padding=2)
        ax.tick_params(axis="x", labelsize=8, rotation=20)
        ax.margins(y=0.18)
        if ax is axes[0]:
            ax.set_ylabel(ylabel)
        ax.grid(axis="y", alpha=0.25)
    fig.suptitle(title, fontweight="bold", fontsize=13)
    fig.tight_layout()
    out = os.path.join(OUT_DIR, fname)
    fig.savefig(out, dpi=130)
    plt.close(fig)
    print(f"  -> {out}")


def speedup_chart(data, fname):
    fig, ax = plt.subplots(figsize=(8.5, 4.5))
    x = np.arange(len(ENDPOINTS))
    w = 0.36
    fr = [data[("frankenphp", ep)]["rps"] / data[("fpm", ep)]["rps"] for ep in ENDPOINTS]
    sw = [data[("swoole", ep)]["rps"] / data[("fpm", ep)]["rps"] for ep in ENDPOINTS]
    b1 = ax.bar(x - w / 2, fr, w, label="FrankenPHP", color=COLORS["frankenphp"])
    b2 = ax.bar(x + w / 2, sw, w, label="Swoole", color=COLORS["swoole"])
    ax.axhline(1.0, ls="--", color="#888", lw=1)
    ax.text(len(ENDPOINTS) - 0.5, 1.02, "baseline FPM = 1,0x", color="#888", fontsize=8, ha="right")
    ax.bar_label(b1, fmt="%.2fx", fontsize=8, padding=2)
    ax.bar_label(b2, fmt="%.2fx", fontsize=8, padding=2)
    ax.set_xticks(x)
    ax.set_xticklabels([f"/bench/{e}" for e in ENDPOINTS])
    ax.set_ylabel("speedup de throughput vs FPM")
    ax.set_title("Quantas vezes mais rápido que o PHP-FPM (req/s)", fontweight="bold", fontsize=12)
    ax.legend()
    ax.grid(axis="y", alpha=0.25)
    ax.margins(y=0.15)
    fig.tight_layout()
    out = os.path.join(OUT_DIR, fname)
    fig.savefig(out, dpi=130)
    plt.close(fig)
    print(f"  -> {out}")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    data = load(sys.argv[1] if len(sys.argv) > 1 else None)
    grouped_by_endpoint(
        data, "rps", "Throughput por endpoint (req/s — maior é melhor)",
        "req/s", "throughput.png", "%.0f",
    )
    grouped_by_endpoint(
        data, "lat_p99", "Latência p99 por endpoint (ms — menor é melhor)",
        "ms", "latency_p99.png", "%.0f",
    )
    speedup_chart(data, "speedup.png")


if __name__ == "__main__":
    main()
