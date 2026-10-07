"""路径与环境常量。

可用环境变量覆盖：
  LMC_REAP_ROOT   Lean/Reap 安装根（含 runtime/ 与 elan/），默认 /mnt/gloway/projects/lean-4.28-reap
  LMC_RUN_DIR     运行目录（shells/logs），默认 ~/lmc-run（ext4；gloway 为 exfat，不适合热状态）
"""

from __future__ import annotations

import os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DEFAULT_REAP_ROOT = Path("/mnt/gloway/projects/lean-4.28-reap")
REAP_ROOT = Path(os.environ.get("LMC_REAP_ROOT", str(DEFAULT_REAP_ROOT)))
PROJECT_DIR = REAP_ROOT / "runtime"
ELAN_HOME = REAP_ROOT / "elan"

RUN_DIR = Path(os.environ.get("LMC_RUN_DIR", str(Path.home() / "lmc-run")))
SHELL_DIR = RUN_DIR / "shells"
LOG_DIR = RUN_DIR / "logs"

PREAMBLE = REPO / "lean" / "lmc_preamble.lean"


def session_env() -> dict[str, str]:
    """给 `lake env lean` 子进程的环境变量。"""
    env = dict(os.environ)
    env["ELAN_HOME"] = str(ELAN_HOME)
    env["PATH"] = f"{ELAN_HOME / 'bin'}:{env.get('PATH', '')}"
    return env
