#!/usr/bin/env bash
# =============================================================================
# setup-lean-env.sh — 在全新 Linux CPU 机器上搭建 lean-mcts-cpu-server 的 Lean 环境
#
# 阶段：
#   1) elan       安装到 <ROOT>/elan
#   2) toolchain  安装 leanprover/lean4:v4.28.0-rc1 并设为默认
#   3) reap       克隆 Reap 源码（github.com/IQuestLab/reap @ 0090d73c）
#   4) overlay    覆盖本仓库 vendor 的 Reap 最终文件（补丁 + 本地对齐改动）
#   5) runtime    生成 runtime lake 项目（Mathlib v4.28.0-rc1）
#   6) cache      lake exe cache get（下载 Mathlib 预编译缓存，最慢的一步）
#   7) build      lake build
#   8) smoke      lake env lean Import.lean（预期输出 LMC-ENV-OK）
#
# 用法：
#   bash env/setup-lean-env.sh                      # 默认装到 ~/lean-4.28-reap
#   bash env/setup-lean-env.sh --root /opt/lean-env
#   LMC_REAP_ROOT=/data/lean bash env/setup-lean-env.sh
#   bash env/setup-lean-env.sh --max-stage 5        # 只跑到第 5 阶段（调试/分步）
#
# 幂等：每阶段完成后写 <ROOT>/state/NN.done；重复执行自动跳过已完成阶段。
# 日志：<ROOT>/logs/setup.log
# 详细前置条件 / 故障排查：docs/FRESH-MACHINE.md
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$REPO_DIR/env"

ROOT="${LMC_REAP_ROOT:-$HOME/lean-4.28-reap}"
MAX_STAGE=8
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="$2"; shift 2 ;;
    --max-stage) MAX_STAGE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done
ROOT="${ROOT/#\~/$HOME}"

ELAN_HOME="$ROOT/elan"
export ELAN_HOME
export PATH="$ELAN_HOME/bin:$PATH"

LEAN_TOOLCHAIN="leanprover/lean4:v4.28.0-rc1"
REAP_URL="https://github.com/IQuestLab/reap.git"
REAP_COMMIT="0090d73c5f739e4d74000e053b00fd0148ff46aa"

mkdir -p "$ROOT"/{logs,state,runtime}
LOG="$ROOT/logs/setup.log"
if [ -t 1 ]; then
  exec > >(tee -a "$LOG") 2>&1
else
  exec >> "$LOG" 2>&1
fi

stage_done() { [ -f "$ROOT/state/$1.done" ]; }
mark()       { touch "$ROOT/state/$1.done"; }
should_run() { ! stage_done "$1" && [ "$((10#$1))" -le "$MAX_STAGE" ]; }

echo "=================================================="
echo "[$(date -Is)] setup start  ROOT=$ROOT  max-stage=$MAX_STAGE"
echo "=================================================="

# ---------------------------------------------------------------------------
# 0. 预检（不设标记，永远执行）
# ---------------------------------------------------------------------------
echo
echo "[0] 预检"
for c in git curl python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c，请先安装"; exit 1; }
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' \
  || { echo "需要 Python >= 3.10（lmc 使用了现代类型语法）"; exit 1; }
echo "    python3 $(python3 -V 2>&1 | awk '{print $2}')"

if ln -s /dev/null "$ROOT/state/.symlink-test" 2>/dev/null; then
  rm -f "$ROOT/state/.symlink-test"
else
  echo "错误：$ROOT 所在文件系统不支持符号链接（如 exfat/FAT/NTFS）。"
  echo "      elan 与 lake 依赖符号链接。请把 ROOT 放到 ext4/xfs，"
  echo "      或参考 docs/FRESH-MACHINE.md §4 的 bind-mount 方案。"
  exit 1
fi

AVG_GB=$(df -Pk "$ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [ "$AVG_GB" -lt 15 ]; then
  echo "警告：$ROOT 所在分区可用空间约 ${AVG_GB}GB，建议 ≥ 20GB（Mathlib 缓存 + 构建产物约 8–10GB）。"
fi

# ---------------------------------------------------------------------------
# 1. elan
# ---------------------------------------------------------------------------
if should_run 01; then
  echo
  echo "[1] 安装 elan → $ELAN_HOME"
  if [ ! -x "$ELAN_HOME/bin/elan" ]; then
    curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -o "$ROOT/elan-init.sh"
    sh "$ROOT/elan-init.sh" -y --default-toolchain none
  fi
  "$ELAN_HOME/bin/elan" --version
  mark 01
fi

# ---------------------------------------------------------------------------
# 2. toolchain
# ---------------------------------------------------------------------------
if should_run 02; then
  echo
  echo "[2] 安装 toolchain $LEAN_TOOLCHAIN"
  "$ELAN_HOME/bin/elan" toolchain install "$LEAN_TOOLCHAIN"
  "$ELAN_HOME/bin/elan" default "$LEAN_TOOLCHAIN"
  "$ELAN_HOME/bin/lean" --version
  mark 02
fi

# ---------------------------------------------------------------------------
# 3. reap source
# ---------------------------------------------------------------------------
if should_run 03; then
  echo
  echo "[3] 克隆 Reap @ $REAP_COMMIT"
  if [ ! -d "$ROOT/reap/.git" ]; then
    mkdir -p "$ROOT/reap"
    git -C "$ROOT/reap" init -q
    git -C "$ROOT/reap" remote add origin "$REAP_URL" 2>/dev/null || true
  fi
  git -C "$ROOT/reap" remote set-url origin "$REAP_URL" 2>/dev/null || true
  if ! git -C "$ROOT/reap" cat-file -e "$REAP_COMMIT^{commit}" 2>/dev/null; then
    if ! git -C "$ROOT/reap" fetch --depth 1 origin "$REAP_COMMIT"; then
      echo "    按 commit 浅取失败，退回完整 fetch…"
      git -C "$ROOT/reap" fetch origin
    fi
  fi
  git -C "$ROOT/reap" checkout -q --detach "$REAP_COMMIT" \
    || git -C "$ROOT/reap" checkout -q --detach FETCH_HEAD
  ACTUAL="$(git -C "$ROOT/reap" rev-parse HEAD)"
  [ "$ACTUAL" = "$REAP_COMMIT" ] || { echo "reap 版本不符: $ACTUAL"; exit 1; }
  mark 03
fi

# ---------------------------------------------------------------------------
# 4. vendored final files（补丁后的最终工作区快照）
# ---------------------------------------------------------------------------
if should_run 04; then
  echo
  echo "[4] 覆盖 vendored Reap 文件（env/reap-final/）"
  ( cd "$ENV_DIR/reap-final" \
    && find . -type f ! -name 'MANIFEST.sha256' -print0 \
    | while IFS= read -r -d '' f; do
        install -D -m 0644 "$f" "$ROOT/reap/${f#./}"
      done )
  ( cd "$ROOT/reap" && sha256sum -c "$ENV_DIR/reap-final/MANIFEST.sha256" )
  mark 04
fi

# ---------------------------------------------------------------------------
# 5. runtime project files
# ---------------------------------------------------------------------------
if should_run 05; then
  echo
  echo "[5] 生成 runtime lake 项目"
  mkdir -p "$ROOT/runtime"
  cp "$ENV_DIR/runtime/lean-toolchain"    "$ROOT/runtime/"
  cp "$ENV_DIR/runtime/lakefile.toml"     "$ROOT/runtime/"
  cp "$ENV_DIR/runtime/ReapRuntime.lean"  "$ROOT/runtime/"
  cp "$ENV_DIR/runtime/Smoke.lean"        "$ROOT/runtime/"
  cp "$ENV_DIR/runtime/Import.lean"       "$ROOT/runtime/"
  cp "$ENV_DIR/runtime/lake-manifest.json" "$ROOT/runtime/"
  mark 05
fi

# ---------------------------------------------------------------------------
# 6. mathlib cache
# ---------------------------------------------------------------------------
if should_run 06; then
  echo
  echo "[6] lake exe cache get（下载 Mathlib 预编译缓存，可能数 GB / 数分钟）"
  ( cd "$ROOT/runtime" && "$ELAN_HOME/bin/lake" exe cache get ) \
    || { echo "    第一次失败，重试一次…"; ( cd "$ROOT/runtime" && "$ELAN_HOME/bin/lake" exe cache get ); }
  mark 06
fi

# ---------------------------------------------------------------------------
# 7. build
# ---------------------------------------------------------------------------
if should_run 07; then
  echo
  echo "[7] lake build"
  ( cd "$ROOT/runtime" && "$ELAN_HOME/bin/lake" build )
  mark 07
fi

# ---------------------------------------------------------------------------
# 8. smoke
# ---------------------------------------------------------------------------
if should_run 08; then
  echo
  echo "[8] 冒烟：lake env lean Import.lean（预期 LMC-ENV-OK）"
  if OUT="$( (cd "$ROOT/runtime" && "$ELAN_HOME/bin/lake" env lean Import.lean) 2>&1 )"; then
    echo "$OUT"
    echo "$OUT" | grep -q "LMC-ENV-OK" || { echo "冒烟失败：未见 LMC-ENV-OK"; exit 1; }
    mark 08
  else
    echo "$OUT"
    echo "冒烟失败：lake env lean Import.lean 非零退出"
    exit 1
  fi
fi

echo
echo "=================================================="
if [ "$MAX_STAGE" -lt 8 ]; then
  echo "已按 --max-stage $MAX_STAGE 完成；继续安装请重跑同一命令（幂等）。"
else
  echo "环境安装完成 → $ROOT"
fi
echo
echo "下一步："
echo "  export LMC_REAP_ROOT=$ROOT"
echo "  cd $REPO_DIR"
echo "  python3 -m lmc.cli smoke        # 会话+验证冒烟"
echo "  python3 -m lmc.cli mcts-smoke   # Python MCTS 端到端冒烟"
echo "=================================================="
