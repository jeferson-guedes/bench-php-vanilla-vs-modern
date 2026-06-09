"""
loadtest.py - Gerador de carga assincrono para o benchmark dos 3 runtimes PHP.

Pode ser usado de duas formas:

1) CLI:
     python bench/loadtest.py --duration 30 --conn 100 --warmup 5
     python bench/loadtest.py -e cpu-bound -s fpm,swoole

2) Importado no notebook (benchmark.ipynb):
     from loadtest import run_matrix, SCENARIOS, ENDPOINTS
     results = await run_matrix(duration=20, conn=100)

Estrategia: para cada (cenario x endpoint), dispara `conn` workers concorrentes
que batem no endpoint em loop por `duration` segundos. Antes de medir, roda um
`warmup` descartado (deixa o JIT compilar e os workers FrankenPHP/Swoole esquentarem).
Coleta latencia de cada request e calcula rps + percentis (p50/p90/p99).
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import math
import os
import time
from datetime import datetime

import aiohttp

# Cenario -> porta externa (ver docker-compose.yml)
SCENARIOS: dict[str, int] = {
    "fpm": 8081,
    "frankenphp": 8182,  # :8082 do host estava ocupada -> Traefik publica FrankenPHP em 8182
    "swoole": 8083,
}

# Endpoint -> (path, metodo). io-write via GET gera payload aleatorio no controller.
ENDPOINTS: dict[str, tuple[str, str]] = {
    "cpu-bound": ("/bench/cpu-bound?n=50000&hashes=3&cost=10", "GET"),
    "io-read":   ("/bench/io-read", "GET"),
    "io-write":  ("/bench/io-write", "GET"),
}

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")


def _pct(sorted_vals: list[float], p: float) -> float:
    """Percentil por interpolacao linear (p em 0..100)."""
    if not sorted_vals:
        return 0.0
    k = (len(sorted_vals) - 1) * p / 100.0
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] * (c - k) + sorted_vals[c] * (k - f)


async def _worker(session, method, url, deadline, latencies, statuses):
    """Bate no endpoint em loop ate o deadline, registrando latencia e status."""
    while time.monotonic() < deadline:
        t0 = time.perf_counter()
        try:
            async with session.request(method, url) as resp:
                await resp.read()
                statuses.append(resp.status)
                latencies.append((time.perf_counter() - t0) * 1000.0)
        except Exception:
            statuses.append(0)  # 0 = falha de conexao/timeout


async def run_target(
    scenario: str,
    endpoint: str,
    *,
    host: str = "localhost",
    conn: int = 100,
    duration: float = 30.0,
) -> dict:
    """Roda uma medicao de um (cenario x endpoint) e devolve as metricas."""
    port = SCENARIOS[scenario]
    path, method = ENDPOINTS[endpoint]
    url = f"http://{host}:{port}{path}"

    latencies: list[float] = []
    statuses: list[int] = []

    connector = aiohttp.TCPConnector(limit=conn, force_close=False)
    timeout = aiohttp.ClientTimeout(total=30)
    started = time.monotonic()
    deadline = started + duration

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        tasks = [
            asyncio.create_task(_worker(session, method, url, deadline, latencies, statuses))
            for _ in range(conn)
        ]
        await asyncio.gather(*tasks)

    elapsed = time.monotonic() - started
    latencies.sort()
    completed = len(statuses)
    non2xx = sum(1 for s in statuses if s == 0 or s >= 400)

    return {
        "scenario": scenario,
        "endpoint": endpoint,
        "url": url,
        "connections": conn,
        "duration_s": round(elapsed, 2),
        "completed": completed,
        "rps": round(completed / elapsed, 1) if elapsed else 0.0,
        "lat_avg": round(sum(latencies) / len(latencies), 2) if latencies else 0.0,
        "lat_p50": round(_pct(latencies, 50), 2),
        "lat_p90": round(_pct(latencies, 90), 2),
        "lat_p99": round(_pct(latencies, 99), 2),
        "lat_max": round(latencies[-1], 2) if latencies else 0.0,
        "non2xx": non2xx,
    }


async def _healthy(scenario: str, host: str) -> bool:
    url = f"http://{host}:{SCENARIOS[scenario]}/bench/io-read"
    try:
        timeout = aiohttp.ClientTimeout(total=5)
        async with aiohttp.ClientSession(timeout=timeout) as s:
            async with s.get(url) as r:
                return r.status < 500
    except Exception:
        return False


async def run_matrix(
    scenarios: list[str] | None = None,
    endpoints: list[str] | None = None,
    *,
    host: str = "localhost",
    conn: int = 100,
    duration: float = 30.0,
    warmup: float = 5.0,
    progress=print,
) -> list[dict]:
    """Roda a matriz completa (sequencial) e devolve a lista de resultados."""
    scenarios = scenarios or list(SCENARIOS)
    endpoints = endpoints or list(ENDPOINTS)

    progress(f"Health-check ({host})...")
    active: list[str] = []
    for sc in scenarios:
        ok = await _healthy(sc, host)
        progress(f"  {'ok  ' if ok else 'DOWN'} {sc} -> :{SCENARIOS[sc]}")
        if ok:
            active.append(sc)
    if not active:
        raise RuntimeError("Nenhum cenario respondendo. Rode: docker compose up -d --build")

    results: list[dict] = []
    for ep in endpoints:
        for sc in active:
            progress(f">> {ep:<10} | {sc:<10}")
            if warmup > 0:
                await run_target(sc, ep, host=host, conn=conn, duration=warmup)  # descartado
            res = await run_target(sc, ep, host=host, conn=conn, duration=duration)
            progress(
                f"   {res['rps']:>10.1f} req/s | avg {res['lat_avg']}ms"
                f" | p99 {res['lat_p99']}ms | non2xx {res['non2xx']}"
            )
            results.append(res)
            await asyncio.sleep(1)  # respiro entre alvos
    return results


def save_results(results: list[dict], stamp: str | None = None) -> tuple[str, str]:
    """Salva os resultados em CSV e JSON, devolve (csv_path, json_path)."""
    os.makedirs(RESULTS_DIR, exist_ok=True)
    stamp = stamp or datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = os.path.join(RESULTS_DIR, f"bench_{stamp}.csv")
    json_path = os.path.join(RESULTS_DIR, f"bench_{stamp}.json")

    cols = [
        "scenario", "endpoint", "connections", "duration_s", "completed",
        "rps", "lat_avg", "lat_p50", "lat_p90", "lat_p99", "lat_max", "non2xx", "url",
    ]
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in cols})
    with open(json_path, "w") as f:
        json.dump(results, f, indent=2)
    return csv_path, json_path


def _parse_args():
    p = argparse.ArgumentParser(description="Load test dos 3 runtimes PHP")
    p.add_argument("-d", "--duration", type=float, default=30.0)
    p.add_argument("-c", "--conn", type=int, default=100)
    p.add_argument("-w", "--warmup", type=float, default=5.0)
    p.add_argument("--host", default="localhost")
    p.add_argument("-s", "--scenarios", default=",".join(SCENARIOS))
    p.add_argument("-e", "--endpoints", default=",".join(ENDPOINTS))
    return p.parse_args()


async def _amain():
    a = _parse_args()
    results = await run_matrix(
        scenarios=[x.strip() for x in a.scenarios.split(",") if x.strip()],
        endpoints=[x.strip() for x in a.endpoints.split(",") if x.strip()],
        host=a.host, conn=a.conn, duration=a.duration, warmup=a.warmup,
    )
    csv_path, json_path = save_results(results)
    print(f"\nCSV:  {csv_path}\nJSON: {json_path}")


if __name__ == "__main__":
    asyncio.run(_amain())
