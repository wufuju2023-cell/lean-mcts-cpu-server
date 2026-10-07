"""Shell 文件生成：把问题文件改造成「会话 shell」。

规则：
  1. 把目标定理的证明体（`reapTrainingMCTS` / `reapMCTS` / `sorry`）替换为 `lmcSessionLoop`；
  2. 在最后一个 import 行之后补 `import ReapRuntime`（若缺）与
     `import Lean.Data.Json.Parser`，并注入 eval 会话 preamble
     （见 lean/lmc_preamble.lean）。
"""

from __future__ import annotations

import re
from pathlib import Path

from .paths import PREAMBLE, SHELL_DIR

REQUIRED_IMPORTS = ("import ReapRuntime", "import Lean.Data.Json.Parser")


def _read_preamble() -> str:
    return PREAMBLE.read_text(encoding="utf-8")


def _replace_proof(text: str, with_text: str) -> str:
    for token in ("reapTrainingMCTS", "reapMCTS"):
        if token in text:
            return text.replace(token, with_text, 1)
    if re.search(r"\bsorry\b", text):
        idx = text.rfind("sorry")
        return text[:idx] + with_text + text[idx + len("sorry"):]
    raise ValueError("no proof placeholder (reapTrainingMCTS / reapMCTS / sorry) found")


def _inject_after_imports(text: str, injection_lines: list[str]) -> str:
    lines = text.split("\n")
    import_idx = [i for i, l in enumerate(lines) if l.startswith("import ")]
    if not import_idx:
        raise ValueError("no import line found")
    last = import_idx[-1]
    return "\n".join(lines[: last + 1] + injection_lines + lines[last + 1:])


def _needed_imports(text: str) -> list[str]:
    return [imp for imp in REQUIRED_IMPORTS if imp not in text]


def build_shell(src: str | Path, out: str | Path | None = None) -> Path:
    """生成会话 shell：证明体替换为 lmcSessionLoop + 注入 preamble。"""
    src = Path(src)
    text = src.read_text(encoding="utf-8")
    text = _replace_proof(text, "lmcSessionLoop")
    inject: list[str] = [""]
    inject.extend(_needed_imports(text))
    inject.append("")
    inject.extend(_read_preamble().split("\n"))
    inject.append("")
    text = _inject_after_imports(text, inject)
    if out is None:
        out = SHELL_DIR / (src.stem + ".lmc.lean")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    return out


def build_direct_shell(src: str | Path, out: str | Path | None = None,
                       *, script: list[str]) -> Path:
    """旧式对照：证明体直接替换为给定剧本（整文件编译，无会话循环）。"""
    src = Path(src)
    text = src.read_text(encoding="utf-8")
    text = _replace_proof(text, "\n  ".join(script))
    if out is None:
        out = SHELL_DIR / (src.stem + ".direct.lean")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    return out
