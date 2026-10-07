"""CLI 入口：python3 -m lmc.cli <cmd>。"""

from __future__ import annotations

import argparse

from . import bench


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lmc", description="lean-mcts-cpu-server CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("smoke", help="单会话脚本冒烟（goals → 3 applies → verify）")
    sub.add_parser("mcts-smoke", help="Python MCTS 端到端冒烟（Pell 第一课）")

    p_lat = sub.add_parser("latency", help="单会话混合负载延迟分布")
    p_lat.add_argument("--cycles", type=int, default=60)

    p_scale = sub.add_parser("scale", help="N 会话并发吞吐扫描")
    p_scale.add_argument("--sessions", default="1,2,4")
    p_scale.add_argument("--cycles", type=int, default=10)

    sub.add_parser("compare", help="旧式整文件编译 vs 新式会话增量")

    p_wave = sub.add_parser("wave", help="波次测试：多题并发端到端（20x200 v001）")
    p_wave.add_argument("--problems", type=int, default=8)
    p_wave.add_argument("--workers", type=int, default=4)
    p_wave.add_argument("--no-verify", action="store_true")

    args = parser.parse_args(argv)
    if args.cmd == "smoke":
        return 0 if bench.smoke() else 1
    if args.cmd == "mcts-smoke":
        return 0 if bench.mcts_smoke() else 1
    if args.cmd == "latency":
        bench.latency(args.cycles)
        return 0
    if args.cmd == "scale":
        sessions = [int(x) for x in args.sessions.split(",") if x.strip()]
        bench.scale(sessions, args.cycles)
        return 0
    if args.cmd == "compare":
        bench.compare()
        return 0
    if args.cmd == "wave":
        bench.wave(args.problems, args.workers, verify=not args.no_verify)
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
