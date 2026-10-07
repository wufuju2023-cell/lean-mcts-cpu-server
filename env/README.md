# env/ — 全新机器环境构建材料

本目录是 `docs/FRESH-MACHINE.md` 里一键安装脚本（`setup-lean-env.sh`）所需的全部材料，
目标：**在没有 GPU、没有预装 Lean 的 Linux 机器上，从零复现本 server 的 Lean 环境**。

## 内容

| 路径 | 说明 |
|---|---|
| `setup-lean-env.sh` | 一键安装（8 阶段、幂等、`--root` / `--max-stage` 参数） |
| `reap-final/` | **Reap 最终工作区文件快照**（upstream@0090d73c + 补丁 + 本地对齐改动），含 `MANIFEST.sha256` |
| `runtime/` | runtime lake 项目：`lean-toolchain`（v4.28.0-rc1）、`lakefile.toml`、`ReapRuntime.lean`、`Smoke.lean`、`Import.lean`（环境冒烟）、`lake-manifest.json`（Mathlib 锁） |
| `upstream/` | 上游交付物原文（对照/溯源用）：补丁 `0001–0004`、base overlay、selection-value-refresh overlay、Reap LICENSE（Apache-2.0） |

## 版本锁定

```text
Lean    : leanprover/lean4:v4.28.0-rc1
Reap    : github.com/IQuestLab/reap @ 0090d73c5f739e4d74000e053b00fd0148ff46aa
Mathlib : leanprover-community/mathlib4 @ v4.28.0-rc1（commit 见 runtime/lake-manifest.json）
```

## 为什么是"最终文件快照"而不是"重放补丁"

开发机（`my-new-linux`）上的 Reap 工作区由三段构成：

1. upstream `0090d73c`；
2. 上游补丁 `0001–0003` + base overlay（`Reap/Training.lean`、`Reap/Training/{Observer,RolloutSink}.lean`）；
3. **本地对齐改动**（不在任何交付补丁里）：例如 `Reap/Options.lean` 的
   `prior_temperature=200`、`c_and` / `unvisited_penalty` / `no_legal_actions_value` 选项，
   以及 `TreeSearch.lean` 的相应调整。

第 3 段无法用上游补丁回放，因此本目录直接固化**最终文件**（`reap-final/`，共 6 个文件），
安装 = clone upstream + 覆盖这 6 个文件 + sha256 校验。补丁与 overlay 原文仍收录在
`upstream/` 供对照；Reap 为 Apache-2.0（见 `upstream/LICENSE.reap`），修改与出处说明见本文件。

## 变更记录（相对 upstream 的 vendored 文件）

```text
Reap/Options.lean           修改：prior_temperature 50→200；新增 c_and=64、unvisited_penalty=32、no_legal_actions_value=-40
Reap/Tactic/Generator.lean  修改：补丁 0001/0003（training endpoints / strict value errors 等）
Reap/Tactic/TreeSearch.lean 修改：补丁 0002 + 本地对齐（AND 节点 c_AND、unvisited 惩罚等）
Reap/Training.lean          新增：base overlay（module / public meta import RolloutSink）
Reap/Training/Observer.lean 新增：base overlay（观测事件、checkpoint 协议）
Reap/Training/RolloutSink.lean 新增：base overlay（rollout 落盘、reapTrainingMCTS 入口）
```

> 注：`selection-value-refresh`（补丁 0004 + `SelectionValueRefresh.lean`）**未启用**；
> 其原文收录在 `upstream/selection-value-refresh-overlay/` 与 `upstream/patches/`。
