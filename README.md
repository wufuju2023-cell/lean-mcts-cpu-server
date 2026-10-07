# lean-mcts-cpu-server

CPU 侧 Lean 会话服务器 + Python MCTS（**0 GPU 可跑**）。

- **定位**：为 AlphaProof 风格的搜索提供一个 CPU 侧、可交互、毫秒级的 Lean 状态机与验证后端。
  单步战术验证 = 会话内 elaboration（实测 1–6ms）；完整内核检查只在收官时做（`verify`/文件编译）。
- **姊妹仓库**：[`wufuju2023-cell/10-4-alpha-proof`](https://github.com/wufuju2023-cell/10-4-alpha-proof)
  （实验、课程、CE/Online-v2 对照；本 server 的设计规格与其 `docs/new-python-version-mcts-plan/` 对应）。
- **环境**：Lean `v4.28.0-rc1` + 打过补丁的 [Reap](https://github.com/IQuestLab/reap) @ `0090d73c` + Mathlib rc1 缓存。

---

## 快速开始

### A. 全新机器（从零装 Lean 环境）

```bash
git clone https://github.com/wufuju2023-cell/lean-mcts-cpu-server.git
cd lean-mcts-cpu-server
bash env/setup-lean-env.sh          # 默认装到 ~/lean-4.28-reap（约 8–10GB，20–60 分钟）

export LMC_REAP_ROOT="$HOME/lean-4.28-reap"
python3 -m lmc.cli smoke            # 单会话：goals → apply×3 → verify → close
python3 -m lmc.cli mcts-smoke       # Python MCTS 端到端（Pell 第一课）
```

> 完整前置条件、分阶段说明、文件系统要求（exfat 的 bind-mount 方案）、故障排查：
> **[`docs/FRESH-MACHINE.md`](docs/FRESH-MACHINE.md)**。

### B. 已有 Lean 环境

```bash
export LMC_REAP_ROOT=/path/to/lean-4.28-reap     # 需含 runtime/（lake 项目）与 elan/
python3 -m lmc.cli smoke
```

---

## 目录结构

```text
lmc/                  Python 包（客户端 + MCTS + 基准）
  paths.py            路径常量（LMC_REAP_ROOT / LMC_RUN_DIR 可覆盖）
  shells.py           从问题文件生成「会话 shell」（注入 preamble + 替换证明体）
  session.py          Lean 会话客户端（JSON Lines stdio 协议）
  mcts.py             对齐官方语义的 Python PUCT MCTS
  policy.py           脚本化 policy（无 GPU 冒烟）
  bench.py            基准：smoke / mcts-smoke / latency / scale / wave / compare
  cli.py              `python3 -m lmc.cli ...`
lean/
  lmc_preamble.lean   注入到 shell 的 Lean 侧会话循环（lmcSessionLoop tactic）
env/                  全新机器环境（见 env/README.md）
  setup-lean-env.sh   一键安装脚本（幂等，8 阶段）
  reap-final/         Reap 最终工作区文件快照 + MANIFEST.sha256
  runtime/            runtime lake 项目（lean-toolchain / lakefile / ReapRuntime / Smoke / Import / manifest）
  upstream/           上游补丁 0001–0004、overlay 原文、Reap LICENSE（Apache-2.0）
examples/             示例题（Pell 冒烟 + FATE-M v001 ×20）
docs/
  FRESH-MACHINE.md    全新机器搭建指南
  BENCH-2026-10-07.md 基准报告
```

---

## 运行命令

```bash
python3 -m lmc.cli smoke          # 单会话脚本冒烟（goals → 3 applies → verify）
python3 -m lmc.cli mcts-smoke     # Python MCTS 端到端冒烟（Pell 第一课）
python3 -m lmc.cli latency        # 单会话混合负载延迟分布（--cycles N）
python3 -m lmc.cli scale --sessions 1,2,4 --cycles 10   # N 会话并发吞吐扫描
python3 -m lmc.cli wave --problems 8 --workers 4        # 波次测试（FATE v001，并发端到端）
python3 -m lmc.cli compare        # 旧式整文件编译 vs 会话增量
```

产物写入 `$LMC_RUN_DIR/logs/lmc-bench-*.json`（默认 `~/lmc-run`，建议放本地盘）。

### 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `LMC_REAP_ROOT` | `/mnt/gloway/projects/lean-4.28-reap` | Lean 环境根（含 `runtime/`、`elan/`） |
| `LMC_RUN_DIR` | `~/lmc-run` | 运行目录（shell 与日志） |
| `LMC_PELL_SMOKE` | 仓库内 `examples/pell_smoke/...` | 覆盖 Pell 冒烟题 |
| `LMC_FATE_ROOT` | 仓库内 `examples/fate_m_v001/` | 覆盖 FATE 题集目录（可指向全量 20x200 解压目录） |

---

## 会话协议（stdin/stdout JSON Lines，响应前缀 `@@LMC@@ `）

| op | 请求 | 响应 |
|---|---|---|
| `ping` | `{id}` | `{ok, kind:"pong", states}` |
| `goals` | `{id, state}` | `{ok, num_goals, goals:[txt]}` |
| `apply` | `{id, state, tactic}` | `{ok, state, num_goals, closed, goals, state_key, elapsed_ms}` 或 `{ok:false, kind:"tactic", error}` |
| `focus` | `{id, state, index}` | `{ok, state, num_goals:1, goals, state_key}` |
| `verify` | `{id, state, script:[...]}` | `{ok, verified, steps}` |
| `close` | `{id}` | `{ok, kind:"closing"}`（随后进程收尾退出） |

### 语义

- 状态句柄 = `Tactic.SavedState` 快照；`apply` 从任意历史状态继续 → 分支正确。
- 失败回滚：apply 报错时恢复原状态，不污染其他分支。
- `verify`：从根状态重放脚本 + 内核检查（`checkProof`）；通过后 shell 文件按真实证明收尾，
  否则恢复根状态并 `admitGoal`（文件可编译，带 sorry 警告）。
- 版本锁：Lean `v4.28.0-rc1` + Reap `0090d73c` + vendored 最终文件（见 `env/README.md`）。

---

## 基准（2026-10-07）

见 [`docs/BENCH-2026-10-07.md`](docs/BENCH-2026-10-07.md)。摘要：

- 单步 `apply` 常规 1–6ms；`nlinarith` 约 280ms（战术本身的代价）；
- 单会话 N=12 饱和约 69 applies/s；20 题波次（6 workers）45.1 题/min；
- 会话增量 vs 整文件编译：稳态约 **18.5×**。

## 状态与路线

- M0 基准 ✅ / M1 walking skeleton ✅ / M2 池化并发（部分；watchdog 待补）
- M3：接入 GPU policy/value（`/eval` 契约）
- M4：轨迹仓库 + export（对接 `update_offline`）

## 许可证

本仓库自有代码未附许可证文件；`env/upstream/LICENSE.reap` 为 vendored 第三方（Reap, Apache-2.0）的许可证原文与出处说明。
