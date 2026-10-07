# 全新机器搭建指南（Lean 环境 + CPU server）

> 目标：在一台**全新的 Linux CPU 机器**上，从零把 `lean-mcts-cpu-server` 跑起来
> （Lean/Reap 环境 + Python MCTS + 端到端冒烟）。
> 参考耗时：网络顺畅时 20–60 分钟（大头是 Mathlib 缓存下载）。
> 参考磁盘：≥ 20GB 可用空间；最终占用约 8–10GB。

---

## 1. 组件关系

```text
┌────────────────────────────┐        JSON-Lines (stdin/stdout + FIFO)
│ python3 -m lmc.cli ...     │  ←────────────────────────────────────┐
│  lmc/  （Python MCTS 等）   │                                       │
└─────────────┬──────────────┘                                       │
              │ 启动每个会话：lake env lean <shell.lean>              │
              ▼                                                      │
┌────────────────────────────┐  注入 lmcSessionLoop（lean/lmc_preamble.lean）
│ <ROOT>/runtime（lake 项目） │  ────────────────────────────────────┘
│  Mathlib v4.28.0-rc1       │
│  ↑ path dependency         │
│ <ROOT>/reap （Reap 源码）   │  ← IQuestLab/reap @0090d73c + vendored 最终文件
│ <ROOT>/elan （Lean rc1）    │
└────────────────────────────┘
```

- `<ROOT>` 默认 `~/lean-4.28-reap`，可用 `--root` 或 `LMC_REAP_ROOT` 覆盖。
- server 代码用 `LMC_REAP_ROOT` 找到 `<ROOT>/runtime` 与 `<ROOT>/elan` 来启动 Lean。

---

## 2. 前置条件

| 项 | 要求 |
|---|---|
| 操作系统 | Linux x86_64（本环境基于 Debian/Ubuntu 构建；其它发行版未验证） |
| 磁盘 | 可用 ≥ 20GB（Mathlib 缓存 + 构建产物约 8–10GB） |
| 网络 | 能访问 `github.com`、`raw.githubusercontent.com`、Mathlib 缓存服务器（`lake exe cache get`） |
| 文件系统 | **必须支持符号链接**（ext4/xfs…；exfat/FAT/NTFS 不行） |
| 工具 | `git`、`curl`、`python3 ≥ 3.10`（lmc 只用标准库） |
| 内存 | 建议 ≥ 8GB（Lean 编译 Mathlib 缓存时主要吃磁盘，不吃太多内存） |

> 服务器代码（`lmc/`）**不依赖 GPU、不依赖 pip 包**；只有 Lean 环境安装需要网络。

---

## 3. 快速开始（TL;DR）

```bash
# 1) 克隆本仓库
git clone https://github.com/wufuju2023-cell/lean-mcts-cpu-server.git
cd lean-mcts-cpu-server

# 2) 一键安装 Lean/Reap 环境（幂等；默认装到 ~/lean-4.28-reap）
bash env/setup-lean-env.sh

# 3) 指向环境并冒烟
export LMC_REAP_ROOT="$HOME/lean-4.28-reap"     # 若用了 --root 请改为对应路径
python3 -m lmc.cli smoke                         # 单会话：goals→apply×3→verify
python3 -m lmc.cli mcts-smoke                    # Python MCTS 端到端（Pell 第一课）
```

预期：`smoke` 输出 `SMOKE: PASS`；`mcts-smoke` 输出 `MCTS-SMOKE: PASS`。

---

## 4. 文件系统与路径（重要）

`elan` 与 `lake` 会在安装目录里创建**符号链接**。如果目标目录在 exfat 这类不支持
符号链接的文件系统上，安装会失败。两种做法：

- **推荐**：把 `<ROOT>` 直接放在 ext4/xfs 上（例如 `~/lean-4.28-reap`）。
- 如果你必须让 `<ROOT>` 出现在一个不佳的文件系统路径（例如项目数据盘 `/mnt/data`），
  可以“ext4 实体目录 + bind mount”映射过去：

```bash
sudo mkdir -p /mnt/data/lean-4.28-reap /home/$USER/lean-4.28-reap
sudo mount --bind /home/$USER/lean-4.28-reap /mnt/data/lean-4.28-reap
# 需要持久化时把下面一行加进 /etc/fstab：
# /home/<user>/lean-4.28-reap /mnt/data/lean-4.28-reap none bind 0 0
bash env/setup-lean-env.sh --root /mnt/data/lean-4.28-reap
```

> 本项目的开发机（`my-new-linux`）正是因为 gloway 盘是 exfat，采用了这套 bind-mount 方案：
> 实体在 `/home/a/lean-4.28-reap`，挂载点 `/mnt/gloway/projects/lean-4.28-reap`。

---

## 5. 安装脚本分阶段说明

`env/setup-lean-env.sh` 分 8 个阶段执行，每个阶段完成后写 `<ROOT>/state/NN.done`，
重复执行会自动跳过；日志在 `<ROOT>/logs/setup.log`。也可以 `--max-stage N` 只跑到
第 N 阶段（分步安装/调试）。

| 阶段 | 做什么 | 网络 | 预计耗时 |
|---|---|---|---|
| 1 | 安装 `elan` 到 `<ROOT>/elan` | 下载 elan | < 1 分钟 |
| 2 | 安装 `leanprover/lean4:v4.28.0-rc1` | 下载 toolchain | 1–5 分钟 |
| 3 | 克隆 `IQuestLab/reap` @ `0090d73c`（浅取该 commit） | ~20MB | < 1 分钟 |
| 4 | 覆盖 vendored Reap 最终文件 + sha256 校验 | 无 | < 1 分钟 |
| 5 | 生成 `<ROOT>/runtime` lake 项目（Mathlib rc1） | 无 | < 1 分钟 |
| 6 | `lake exe cache get`（下载 Mathlib 预编译缓存） | 数 GB | 10–40 分钟 |
| 7 | `lake build`（借助缓存，构建 ReapRuntime） | 少量 | 2–10 分钟 |
| 8 | `lake env lean Import.lean`，预期输出 `LMC-ENV-OK` | 无 | < 1 分钟 |

安装完成后设置环境变量（建议写进 shell rc）：

```bash
export LMC_REAP_ROOT="$HOME/lean-4.28-reap"
```

若中途失败：看 `<ROOT>/logs/setup.log`；修好后**重跑同一命令**即可（幂等）。
想强制重跑某阶段：删除对应 `<ROOT>/state/NN.done` 再重跑。

---

## 6. 版本锁定与来源

| 组件 | 版本/来源 | 校验方式 |
|---|---|---|
| Lean | `leanprover/lean4:v4.28.0-rc1` | `elan` |
| Reap | `github.com/IQuestLab/reap` @ `0090d73c5f739e4d74000e053b00fd0148ff46aa` | `git rev-parse HEAD` |
| Reap 最终文件 | `env/reap-final/`（6 个文件） | `sha256sum -c env/reap-final/MANIFEST.sha256` |
| Mathlib | tag `v4.28.0-rc1`（commit 见 `env/runtime/lake-manifest.json`） | lake manifest |
| runtime 工程 | `env/runtime/`（lean-toolchain / lakefile / ReapRuntime / Smoke / Import / manifest） | 版本文件 |

**为什么用 "vendored 最终文件" 而不是补丁回放？**
开发机上的 Reap 工作区 = upstream@0090d73c + 上游补丁（0001–0004）+ 本地对齐改动
（例如 `reap.prior_temperature=200`、`c_and/unvisited_penalty` 选项）。其中部分是
容器构建的口传步骤、部分是本地手工调整，**无法用交付补丁完整回放**。为了"全新机器
精确复现"，本仓库直接固化**最终文件快照**；上游补丁与 overlay 原文保留在
`env/upstream/` 供对照与法律/溯源用途（Reap 为 Apache-2.0，见
`env/upstream/LICENSE.reap`）。

---

## 7. 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `LMC_REAP_ROOT` | `/mnt/gloway/projects/lean-4.28-reap` | Lean 环境根（含 `runtime/`、`elan/`）**必设** |
| `LMC_RUN_DIR` | `~/lmc-run` | 运行目录（生成 shell/日志）；建议放本地盘 |
| `LMC_OUTPUT_FIFO` | （会话内部设置） | 会话输出 FIFO；一般不用手动设 |
| `LMC_PELL_SMOKE` | 仓库内 `examples/pell_smoke/...` | 覆盖 Pell 冒烟题文件路径 |
| `LMC_FATE_ROOT` | 仓库内 `examples/fate_m_v001/` | 覆盖 FATE v001 题集目录（全量 20x200 解压目录亦可） |

---

## 8. 验收测试

```bash
cd lean-mcts-cpu-server
export LMC_REAP_ROOT="$HOME/lean-4.28-reap"

python3 -m lmc.cli smoke          # 单会话：goals → 3 applies → verify → close
python3 -m lmc.cli mcts-smoke     # Python MCTS：搜索→脚本→verify
python3 -m lmc.cli wave --problems 4 --workers 2   # 4 题并发波次（约几十秒）
python3 -m lmc.cli latency --cycles 20             # 延迟分布
python3 -m lmc.cli compare                         # 整文件编译 vs 会话增量
```

产物写入 `$LMC_RUN_DIR/logs/lmc-bench-*.json`。

---

## 9. 故障排查

| 现象 | 处理 |
|---|---|
| 阶段 1/2 卡住或超时 | 检查到 `raw.githubusercontent.com` / elan 下载源的网络；可配置代理后重跑 |
| 阶段 3 `fetch --depth 1 <commit>` 失败 | 脚本会自动退回完整 `git fetch`；网络受限时也可先手动 clone 到 `<ROOT>/reap` |
| 阶段 6 cache get 失败 | 重跑一次（脚本内已自动重试一次）；仍失败看是否为缓存服务器网络问题，可先用 `lake build` 硬编（很慢） |
| `lake build` 报版本不匹配 | 确认 `<ROOT>/runtime/lean-toolchain` 为 `v4.28.0-rc1`，且 `elan default` 指向它 |
| `symlink` 报错 | 见 §4：换 ext4 或 bind mount |
| `lmc.cli` 报找不到 Lean | 未设 `LMC_REAP_ROOT`，或路径不含 `runtime/` 与 `elan/` |
| 中文/环境无关的 `lake env lean` 报错 | 用 `bash env/setup-lean-env.sh --max-stage 8` 重跑验收阶段 8（应输出 `LMC-ENV-OK`） |

---

## 10. 手动安装（不用脚本时）

```bash
ROOT=~/lean-4.28-reap
export ELAN_HOME="$ROOT/elan"
export PATH="$ELAN_HOME/bin:$PATH"

# 1) elan
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -y --default-toolchain none

# 2) toolchain
elan toolchain install leanprover/lean4:v4.28.0-rc1
elan default leanprover/lean4:v4.28.0-rc1

# 3) reap
git clone https://github.com/IQuestLab/reap.git "$ROOT/reap"
git -C "$ROOT/reap" checkout 0090d73c5f739e4d74000e053b00fd0148ff46aa

# 4) 覆盖 vendored 文件
cp -r env/reap-final/Reap "$ROOT/reap/"
( cd "$ROOT/reap" && sha256sum -c "$OLDPWD/env/reap-final/MANIFEST.sha256" )

# 5) runtime
mkdir -p "$ROOT/runtime" && cp env/runtime/* "$ROOT/runtime/"

# 6-8) 缓存 / 构建 / 冒烟
cd "$ROOT/runtime"
lake exe cache get
lake build
lake env lean Import.lean    # 预期 LMC-ENV-OK
```

---

## 11. 与上游 v1 容器构建的关系（背景）

本环境对应上游交付中的 CPU 容器两阶段构建：

- **base**：`reap@0090d73c` + 补丁 `0001-training-endpoints-and-value` /
  `0002-training-observer` / `0003-strict-value-errors` + `reap-overlay/`
  （`Reap/Training.lean`、`Reap/Training/{Observer,RolloutSink}.lean`）；
- **selection-value-refresh（可选增量）**：补丁 `0004-selection-value-refresh` +
  `Reap/Training/SelectionValueRefresh.lean`，通过环境变量
  `REAP_SELECTION_VALUE_REFRESH` 显式开启。

> 当前 server 环境**未启用** selection-value-refresh（本地工作区不含
> `SelectionValueRefresh.lean`）；相关文件仍收录在 `env/upstream/` 以便对照。
