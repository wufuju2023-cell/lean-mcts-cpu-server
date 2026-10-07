# examples/ — 示例题

供 `lmc.cli` 的 `smoke / mcts-smoke / wave` 使用（脚本化 policy，无需 GPU）。

| 路径 | 用途 |
|---|---|
| `pell_smoke/PellInvariantSmoke.lean` | 佩尔课程第一课；三步脚本可解（`intro x y h` → `simp only [step]` → `nlinarith [h]`） |
| `fate_m_v001/P01..P20_FATE_M_*/v001.lean` | FATE-M 20 个 family 的 v001（tier-1 direct_target）；`wave` 默认使用 |

覆盖路径（例如改用完整的 20x200 解压目录）：

```bash
export LMC_PELL_SMOKE=/path/to/PellInvariantSmoke.lean
export LMC_FATE_ROOT=/path/to/fate_m_lean_curriculum_20x200_20261004/lean/problems
```

> `LMC_FATE_ROOT` 下的目录名需与 `lmc/bench.py` 的 `FATE_V001` 列表一致（`P01_FATE_M_003` …）。
