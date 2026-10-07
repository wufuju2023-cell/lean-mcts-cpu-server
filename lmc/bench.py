"""Benchmarks: smoke / mcts-smoke / latency / scale / compare."""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .paths import PROJECT_DIR, SHELL_DIR, LOG_DIR, REPO, session_env
from .session import LeanSession
from .shells import build_direct_shell, build_shell

def _env_path(name: str, local: Path, legacy: Path) -> Path:
    """优先环境变量；其次仓库内置 examples；最后回退开发机旧路径。"""
    override = os.environ.get(name)
    if override:
        return Path(override)
    return local if local.exists() else legacy


PELL_SMOKE = _env_path(
    "LMC_PELL_SMOKE",
    REPO / "examples" / "pell_smoke" / "PellInvariantSmoke.lean",
    Path("/mnt/gloway/projects/10-4-alpha-proof/lean/pell_smoke/PellInvariantSmoke.lean"),
)
PELL_SCRIPT = ["intro x y h", "simp only [step]", "nlinarith [h]"]


def _pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    xs = sorted(values)
    k = max(0, min(len(xs) - 1, int(round(q * (len(xs) - 1)))))
    return xs[k]


def _stats(values: list[float]) -> dict:
    return {
        "count": len(values),
        "mean": round(statistics.fmean(values), 2) if values else None,
        "p50": round(_pct(values, 0.50), 2) if values else None,
        "p95": round(_pct(values, 0.95), 2) if values else None,
        "max": round(max(values), 2) if values else None,
    }


def _write_report(name: str, data: dict) -> Path:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"lmc-bench-{name}-{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


# --------------------------------------------------------------------------- #
def smoke() -> bool:
    """单会话：goals → 3 步脚本 → verify → close。"""
    shell = build_shell(PELL_SMOKE, out=SHELL_DIR / "pell_smoke.lmc.lean")
    print(f"shell: {shell}")
    session = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name="smoke")
    print(f"startup (import + ready): {session.startup_s:.2f}s")
    g = session.goals(0)
    print(f"goals[0]: num_goals={g.get('num_goals')}")
    cur = 0
    for tac in PELL_SCRIPT:
        r = session.apply(cur, tac)
        print(
            f"apply {tac!r}: ok={r.ok} closed={r.closed} goals={r.num_goals} "
            f"lean={r.elapsed_ms}ms rtt={r.rtt_ms:.1f}ms"
        )
        if not r.ok:
            raise SystemExit(f"apply failed: {r.error}")
        if r.state is not None:
            cur = r.state
    v = session.verify(0, PELL_SCRIPT)
    print(f"verify: {v}")
    rc = session.close()
    print(f"exit code: {rc}")
    ok = bool(v.get("verified")) and rc == 0
    print("SMOKE:", "PASS" if ok else "FAIL")
    return ok


# --------------------------------------------------------------------------- #
def mcts_smoke() -> bool:
    """Python MCTS 端到端：搜索 → 脚本 → verify。"""
    from .mcts import MCTS, SearchConfig
    from .policy import PELL_CANDIDATES, zero_value

    shell = build_shell(PELL_SMOKE, out=SHELL_DIR / "pell_mcts.lmc.lean")
    session = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name="mcts")
    cfg = SearchConfig(max_nodes=8, max_steps=8, num_samples=4)
    mcts = MCTS(session, lambda _g: PELL_CANDIDATES, zero_value, cfg)
    res = mcts.search(0, "⊢ CourseInvariant")
    print(f"search: solved={res.solved} nodes={res.nodes_created} sims={res.simulations}")
    print(f"script: {res.best_script}")
    if not res.solved:
        session.close()
        print("MCTS-SMOKE: FAIL (not solved)")
        return False
    if res.best_script != PELL_SCRIPT:
        print(f"MCTS-SMOKE: FAIL (unexpected script)")
        session.close()
        return False
    v = session.verify(0, res.best_script)
    print(f"verify: {v}")
    rc = session.close()
    print(f"exit code: {rc}")
    ok = bool(v.get("verified")) and rc == 0
    print("MCTS-SMOKE:", "PASS" if ok else "FAIL")
    return ok


# --------------------------------------------------------------------------- #
def latency(cycles: int = 60) -> dict:
    """单会话混合负载：成功/失败/中等/重量 战术的延迟分布。"""
    shell = build_shell(PELL_SMOKE, out=SHELL_DIR / "pell_latency.lmc.lean")
    s = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name="latency")
    print(f"startup: {s.startup_s:.2f}s")
    r = s.apply(0, "intro x y h")
    assert r.ok, r.error
    s1 = r.state
    r = s.apply(s1, "simp only [step]")
    assert r.ok, r.error
    s2 = r.state

    samples: dict[str, list] = defaultdict(list)
    t0 = time.monotonic()
    for i in range(cycles):
        m = i % 4
        if m == 0:
            r = s.apply(0, "intro x y h")
            label = "intro(ok)"
        elif m == 1:
            r = s.apply(0, "exact h")
            label = "exact-h(err)"
        elif m == 2:
            r = s.apply(s1, "simp only [step]")
            label = "simp(ok)"
        else:
            r = s.apply(s2, "nlinarith [h]")
            label = "nlinarith(close)"
        samples[label].append(r)
    wall = time.monotonic() - t0
    rc = s.close()

    report: dict = {"cycles": cycles, "wall_s": round(wall, 2), "by_label": {}}
    total = sum(len(v) for v in samples.values())
    report["applies"] = total
    report["applies_per_s"] = round(total / wall, 2)
    for label, rs in samples.items():
        rtt = [x.rtt_ms for x in rs if x.rtt_ms is not None]
        lean = [x.elapsed_ms for x in rs if x.elapsed_ms is not None]
        report["by_label"][label] = {
            "n": len(rs),
            "rtt_ms": _stats(rtt),
            "lean_ms": _stats(lean),
            "errors": sum(1 for x in rs if not x.ok),
        }
    report["exit_code"] = rc
    path = _write_report("latency", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"report: {path}")
    return report


# --------------------------------------------------------------------------- #
def scale(sessions_list: list[int], cycles: int) -> dict:
    """并发扫描：N 个会话各跑 cycles 轮（每轮 3 个 apply），测总吞吐。"""
    shell = build_shell(PELL_SMOKE, out=SHELL_DIR / "pell_scale.lmc.lean")
    report: dict = {"cycles": cycles, "shell": str(shell), "results": []}
    for n in sessions_list:
        barrier = threading.Barrier(n)
        results: list[dict | None] = [None] * n

        def worker(i: int) -> None:
            try:
                s = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name=f"scale-{n}-{i}")
                startup = s.startup_s
                barrier.wait()
                rtt: list[float] = []
                lean: list[float] = []
                t0 = time.monotonic()
                for _ in range(cycles):
                    r1 = s.apply(0, "intro x y h")
                    if not r1.ok or r1.state is None:
                        raise RuntimeError(f"intro failed: {r1.error}")
                    r2 = s.apply(r1.state, "simp only [step]")
                    if not r2.ok or r2.state is None:
                        raise RuntimeError(f"simp failed: {r2.error}")
                    r3 = s.apply(r2.state, "nlinarith [h]")
                    if not (r3.ok and r3.closed):
                        raise RuntimeError(f"nlinarith failed: r3={r3.ok}/{r3.closed} {r3.error}")
                    for r in (r1, r2, r3):
                        if r.rtt_ms is not None:
                            rtt.append(r.rtt_ms)
                        if r.elapsed_ms is not None:
                            lean.append(r.elapsed_ms)
                wall = time.monotonic() - t0
                rss = s.rss_mb()
                rc = s.close()
                results[i] = {
                    "startup_s": round(startup, 2),
                    "wall_s": round(wall, 2),
                    "rss_mb": rss,
                    "exit_code": rc,
                    "rtt_ms": _stats(rtt),
                    "lean_ms": _stats(lean),
                }
            except Exception as exc:  # noqa: BLE001
                results[i] = {"error": repr(exc)}

        print(f"--- N={n} ---")
        for i in range(n):
            print(f"  worker {i} started")
        with ThreadPoolExecutor(max_workers=n) as ex:
            futs = [ex.submit(worker, i) for i in range(n)]
            for f in futs:
                f.result()
        entry: dict = {"n": n, "workers": results}
        ok_results = [r for r in results if r and "error" not in r]
        if ok_results:
            max_wall = max(r["wall_s"] for r in ok_results)
            total_applies = n * cycles * 3
            entry["max_wall_s"] = round(max_wall, 2)
            entry["total_applies"] = total_applies
            entry["applies_per_s"] = round(total_applies / max_wall, 2)
            entry["cycles_per_s"] = round(n * cycles / max_wall, 2)
            entry["rss_sum_mb"] = round(sum(r["rss_mb"] or 0 for r in ok_results), 1)
            entry["startup_mean_s"] = round(
                statistics.fmean(r["startup_s"] for r in ok_results), 2
            )
            entry["exit_codes"] = [r["exit_code"] for r in ok_results]
            print(
                f"N={n}: wall={entry['max_wall_s']}s applies/s={entry['applies_per_s']} "
                f"cycles/s={entry['cycles_per_s']} rss={entry['rss_sum_mb']}MB "
                f"startup_mean={entry['startup_mean_s']}s"
            )
        else:
            print(f"N={n}: FAILED {results}")
        report["results"].append(entry)
    path = _write_report("scale", report)
    print(f"report: {path}")
    return report


# --------------------------------------------------------------------------- #
def compare() -> dict:
    """C1：旧式整文件编译 vs 新式会话增量。"""
    direct = build_direct_shell(PELL_SMOKE, out=SHELL_DIR / "pell_direct.lean", script=PELL_SCRIPT)
    old_times: list[float] = []
    for i in range(3):
        t0 = time.monotonic()
        p = subprocess.run(
            ["lake", "env", "lean", str(direct)],
            cwd=PROJECT_DIR,
            env=session_env(),
            capture_output=True,
            text=True,
            timeout=1800,
        )
        dt = time.monotonic() - t0
        old_times.append(dt)
        print(f"old compile run {i}: {dt:.2f}s rc={p.returncode}")
        if p.returncode != 0:
            print(p.stderr[-2000:])
            raise SystemExit("direct compile failed")

    shell = build_shell(PELL_SMOKE, out=SHELL_DIR / "pell_compare.lmc.lean")
    t0 = time.monotonic()
    s = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name="compare")
    startup = time.monotonic() - t0
    applies: list[dict] = []
    t1 = time.monotonic()
    cur = 0
    for tac in PELL_SCRIPT:
        r = s.apply(cur, tac)
        applies.append({"tactic": tac, "ok": r.ok, "lean_ms": r.elapsed_ms, "rtt_ms": r.rtt_ms})
        if r.state is not None:
            cur = r.state
    solve = time.monotonic() - t1
    v = s.verify(0, PELL_SCRIPT)
    rc = s.close()

    old_mean = statistics.fmean(old_times)
    new_total = startup + solve
    report = {
        "old_full_compile_s": [round(x, 2) for x in old_times],
        "old_mean_s": round(old_mean, 2),
        "new_startup_s": round(startup, 2),
        "new_solve_no_startup_s": round(solve, 2),
        "new_total_s": round(new_total, 2),
        "new_applies": applies,
        "verify": v,
        "exit_code": rc,
        "speedup_total": round(old_mean / new_total, 1) if new_total else None,
        "speedup_steady_state": round(old_mean / solve, 1) if solve else None,
        "reference_cloud": {
            "avg_attempt_s": 25.9,
            "lean_share": "96.7%",
            "source": "hsy-的分析 / ModelScope 交付（云端 holdout 评测 103 次尝试）",
        },
    }
    path = _write_report("compare", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"report: {path}")
    return report


# --------------------------------------------------------------------------- #
FATE_ROOT = _env_path(
    "LMC_FATE_ROOT",
    REPO / "examples" / "fate_m_v001",
    Path("/mnt/gloway/projects/10-4-alpha-proof/hsy-的分析/extracted/fate_m_lean_curriculum_20x200_20261004/lean/problems"),
)

FATE_V001 = [
    "P01_FATE_M_003", "P02_FATE_M_004", "P03_FATE_M_009", "P04_FATE_M_011",
    "P05_FATE_M_014", "P06_FATE_M_015", "P07_FATE_M_018", "P08_FATE_M_021",
    "P09_FATE_M_035", "P10_FATE_M_040", "P11_FATE_M_048", "P12_FATE_M_051",
    "P13_FATE_M_052", "P14_FATE_M_061", "P15_FATE_M_064", "P16_FATE_M_065",
    "P17_FATE_M_066", "P18_FATE_M_067", "P19_FATE_M_068", "P20_FATE_M_076",
]


def wave(problems: int = 8, workers: int = 4, verify: bool = True) -> dict:
    """波次测试：每题一个会话（真实 20x200 工作负载），并发 workers 个。

    每会话：open → apply('exact curriculum_target') → verify → close。
    """
    families = FATE_V001[:problems]
    results: list[dict | None] = [None] * len(families)
    sem = threading.Semaphore(workers)
    record = threading.Lock()
    report: dict = {"problems": problems, "workers": workers, "entries": []}

    def run_one(i: int, fam: str) -> None:
        with sem:
            entry: dict = {"family": fam}
            try:
                src = FATE_ROOT / fam / "v001.lean"
                shell = build_shell(src, out=SHELL_DIR / f"{fam}.lmc.lean")
                t0 = time.monotonic()
                s = LeanSession(shell, cwd=PROJECT_DIR, env=session_env(), name=fam)
                entry["startup_s"] = round(s.startup_s, 2)
                r = s.apply(0, "exact curriculum_target")
                entry["apply_ok"] = r.ok
                entry["apply_ms"] = r.elapsed_ms
                if verify:
                    t1 = time.monotonic()
                    v = s.verify(0, ["exact curriculum_target"])
                    entry["verify_s"] = round(time.monotonic() - t1, 2)
                    entry["verified"] = bool(v.get("verified"))
                entry["exit"] = s.close()
                entry["wall_s"] = round(time.monotonic() - t0, 2)
            except Exception as exc:  # noqa: BLE001
                entry["error"] = repr(exc)
            with record:
                results[i] = entry
                print(f"  {fam}: {entry}")

    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(run_one, i, fam) for i, fam in enumerate(families)]
        for f in futs:
            f.result()
    wall = time.monotonic() - t0

    ok = [r for r in results if r and r.get("verified")]
    report["entries"] = results
    report["wall_s"] = round(wall, 2)
    report["solved"] = len(ok)
    report["problems_per_min"] = round(len(ok) / wall * 60, 2) if wall else None
    print(f"WAVE: solved={len(ok)}/{len(families)} wall={wall:.1f}s "
          f"throughput={report['problems_per_min']}/min")
    path = _write_report("wave", report)
    print(f"report: {path}")
    return report
