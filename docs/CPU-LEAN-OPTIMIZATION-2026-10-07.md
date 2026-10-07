# CPU 端 Lean 验证：261007 现状、瓶颈与优化路线

> **截止：2026-10-07（261007）**  
> **性质：GPT 基于当前仓库代码、261007 benchmark、E2“上回轨迹”分析给出的工程建议。**
>
> 当前建议不是“推倒重来换框架”，而是在已经正确的 `Reap + Tactic.SavedState + Python MCTS` 基础上，继续把重复验证、IPC、冷启动和长尾 tactic 的成本压下去。

---

## 1. 先说结论

当前 CPU Lean 已经完成了最重要的一次架构升级：

```text
旧：
每次尝试
→ 新启动 Lean
→ import / elaboration
→ 整文件验证
→ 退出

现在：
一题启动一次 Lean
→ 保存 root SavedState
→ state + tactic
→ restore / execute / save next state
→ MCTS 可以从任意历史 state 分叉
```

因此，**“每一步重新编译 / replay 前缀”已经不是当前主问题。**

接下来最值得做的是：

```text
P0  修正搜索语义
    terminal final-check
    ancestor cycle rejection
    fresh Lean CLI 最终复验

P1  减少无意义的 Lean 调用
    failed-action / transition cache
    apply_batch(K 个 tactic 一次发给 Lean)

P1  降低 verifier 固定开销
    去掉无日志时的重复 proof-state pretty-print
    拆分 restore / parse / tactic / pp / save / IPC 耗时

P2  控制长期运行
    state release
    timeout / watchdog
    RSS watermark / worker recycle

P2/P3
    短题很多时：跨 theorem 常驻 Lean worker
    重 tactic 主导时：再研究 AlphaProof 式 native/C 优化
```

我目前最看好的两个**低风险、高收益**改动是：

> **① `apply_batch`；② deterministic failed-action cache。**

而对大量短课程题，潜力最大的“大改”是：

> **跨 theorem 复用已经加载 Mathlib 的 Lean worker。**

---

## 2. “上一次实验”主要慢在哪里？

这里的“上一次实验”指 2026-10-06 那批训练 / shared rollout 及其旧验证链路；E2 后续分析的是同批轨迹。

旧链路的实测背景记录在：

- `10-4-alpha-proof/docs/new-python-version-mcts-plan/08-testing-and-load-bench.md`
- 当前分支 commit：`c3de72599736fcd1b091c4c97c0d41441881b6bf`

关键数字：

| 指标 | 旧实验 |
|---|---:|
| 初始评测 | 40 题 / 106 attempts |
| 总 wall time | 2839.95 s ≈ 47.3 min |
| GPU 生成 | 70.20 s ≈ 2.5% |
| Lean 验证 | 2747.41 s ≈ **96.7%** |
| 平均 Lean / attempt | ≈ **25.9 s** |
| CE 评测 | 103 attempts / 2761.34 s |
| CE 中 Lean | 2670.39 s |

所以旧实验的主要瓶颈并不是 GPU，而是：

> **每个 attempt 都重新走整文件 Lean 编译 / import / elaboration。**

这也是为什么“加 GPU”基本不能解决问题。

---

## 3. 当前 v0 已经解决了什么？

当前实现仓库：

- `wufuju2023-cell/lean-mcts-cpu-server`
- `main` HEAD：`f707a11a80c24c34d405fdd344255f2394fc21f4`

关键文件：

| 文件 | blob SHA |
|---|---|
| `lean/lmc_preamble.lean` | `80db4243a7eb8f134f88224c4dbd632dacd42c05` |
| `lmc/session.py` | `a04028446fd228f1a62b007f57f387636c49def6` |
| `lmc/mcts.py` | `5b67974884bed3d488973f763ada406ad976ae2a` |
| `docs/BENCH-2026-10-07.md` | `05458ec00d2c69138574cbc049a7037cde4e9666` |

当前已经实现：

```text
Tactic.SavedState
+ 任意历史 state restore
+ tactic 单步执行
+ 成功后保存 next state
+ 失败恢复原 state
+ Python MCTS 分支搜索
```

这与 AlphaProof 论文公开的核心 verifier 思路是一致的：AlphaProof 的 Lean environment 支持保存 / 恢复 / 唯一标识 tactic state，并从已访问状态继续搜索。

AlphaProof 原始论文：

- Nature：  
  https://www.nature.com/articles/s41586-025-09833-y
- 开放全文：  
  https://pmc.ncbi.nlm.nih.gov/articles/PMC12999475/

另一个独立公开工作也说明“保留 proof state 而不是重复重建”非常关键：

- Shen & Shi, *Keep the Proof State Live: Snapshotting for Efficient Tactic Search in Lean 4*  
  https://arxiv.org/abs/2605.25556  
  该工作在其场景中报告了 5.6–50× 的 wall-time speedup（平均约 14×）；这不是我们的 workload，也不能直接套数字，但方向与当前 `SavedState` 路线一致。

**因此现在没有理由仅为了“REPL / state reuse”就迁移 Pantograph。**

---

## 4. 当前 benchmark 告诉我们：瓶颈已经“搬家”

261007 当前实测：

| 项目 | 当前 v0 |
|---|---:|
| 普通 `apply` 的 Lean 执行 | **1–6 ms** |
| `nlinarith` | **约 280 ms** |
| 普通 `intro` RTT | Lean ~1 ms，RTT ~3.5 ms |
| 普通 `simp` RTT | Lean ~4 ms，RTT ~6 ms |
| 单会话 RSS | ~800 MB |
| Lean + Mathlib 冷启动 | **5.6–7.5 s** |
| N=12 吞吐 | ~69 applies/s，之后基本饱和 |
| FATE v001 ×20，6 并发 | **26.6 s，45.1 题/min** |
| 同机整文件 vs 稳态会话 | 稳态约 **18.5×** |

出处：

https://github.com/wufuju2023-cell/lean-mcts-cpu-server/blob/f707a11a80c24c34d405fdd344255f2394fc21f4/docs/BENCH-2026-10-07.md

因此现在必须区分两种 workload。

### A. 很多简单题 / curriculum / evaluation

例如 FATE v001：

```text
真正 tactic：几毫秒
每题启动 Lean：约 6 秒
```

此时**冷启动是绝对主瓶颈**。

### B. 真正的深 MCTS

如果一道题会走：

```text
数百～数千次 apply
并大量使用 nlinarith / linarith / aesop / simp
```

那么 6 秒启动会被摊薄，瓶颈转移到：

```text
重 tactic 本身
+ 重复 tactic
+ Python ↔ Lean 往返
+ proof-state pp
+ state 生命周期
```

这两种场景不能用同一套优化排序。

---

## 5. 我建议的最终 Lean 验证流程

目标流程：

```text
           预热 Lean worker
       Mathlib / Reap 已加载
                 │
                 ▼
            open theorem
                 │
                 ▼
          得到 root state
                 │
                 ▼
        GPU 产生 K 个 tactics
                 │
                 ▼
        精确字符串去重 / cache
                 │
                 ▼
       apply_batch(state, K tactics)
                 │
                 ▼
 Lean 内对每个 tactic：
 restore 同一个 parent state
        │
        ├─ parse/elab/tactic failed
        │     → deterministic negative cache
        │
        ├─ timeout
        │     → timeout 记录；按策略决定是否重试
        │
        └─ success
              → terminal 时做正确 final check
              → ancestor state? 丢弃
              → duplicate state? 合并并 release 临时 state
              → 否则 saveState
                 │
                 ▼
             MCTS 继续
                 │
                 ▼
            找到完整 proof
                 │
                 ▼
       session 内快速 verify
                 │
                 ▼
         生成 final_proof.lean
                 │
                 ▼
       fresh standard Lean CLI
                 │
                 ▼
            PASS 才算成功
```

---

## 6. 优先级 1：先修搜索语义，代价很小

### 6.1 普通 terminal state 应做 `checkProof`

当前 `lmc_preamble.lean` 的 `apply` 对所有状态使用：

```lean
evalTacticStrNoFinalCheck
```

但当前锁定的 Reap 原实现区分：

```text
普通 OR node
→ evalTacticStr

AND focused partial goal
→ evalTacticStrNoFinalCheck
```

Reap 原始源码：

- `TreeSearch.lean`  
  https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/TreeSearch.lean
- `Step.lean`  
  https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/Step.lean

原因很简单：

> 对普通完整目标，如果 tactic 看起来把 goals 清空了，应该在 MCTS 将它标记成 solved 之前完成 proof check。

否则可能出现：

```text
MCTS 认为 solved
→ 提前结束搜索
→ 最后的 verify 才发现此 terminal 不合法
```

建议恢复 Reap 的区别处理。

**性能影响：很小。**  
`evalTacticStr` 只在目标真的闭合时增加 final proof check，不会给每个非 terminal step 都做完整 kernel check。

---

### 6.2 补 ancestor-cycle rejection

Reap 原 MCTS 维护 `ancestorKeys`：

```text
S0 → S1 → S2 → S0
```

若新状态回到当前祖先链，直接拒绝。

出处：

https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/TreeSearch.lean

当前 Python MCTS 已有 sibling duplicate merge，但尚未看到同等的 ancestor 防环。

建议补：

```text
new_state_key ∈ current_path_ancestor_keys
→ ancestor_rejected
```

这同时是**正确性对齐 + CPU 节省**。

---

### 6.3 最终增加 fresh Lean CLI strict lane

当前 session 内 `verify` 是好的快速校验，但建议 solved 后再：

```text
输出完整 .lean
→ fresh `lake env lean final_proof.lean`
→ strict receipt
```

AlphaProof 官方也明确描述了独立 final verification：

https://pmc.ncbi.nlm.nih.gov/articles/PMC12999475/

这个 strict lane 只需 1–2 并发，不进入每一步 MCTS 内循环。

---

## 7. 优先级 2：最值得做的速度优化

### 7.1 `apply_batch`：我最推荐先实现

现在一次 expansion 的 K 个候选是：

```text
Python → Lean → Python
× K
```

当前数据已经说明，对便宜 tactic：

```text
intro：Lean ~1 ms，RTT ~3.5 ms
simp： Lean ~4 ms，RTT ~6 ms
```

也就是通信、JSON、FIFO、queue/thread 唤醒已经和 Lean 本体同量级。

建议：

```json
{
  "op": "apply_batch",
  "state": 17,
  "tactics": ["t1", "t2", "t3", "t4", "t5", "t6"]
}
```

Lean 内：

```text
restore parent
→ t1
restore parent
→ t2
...
```

一次性返回结果。

#### 预计节省

以 K=6、便宜 tactic 为例，目前每个 action 约有 2–3ms 的非 Lean RTT 开销。

粗略估算：

```text
6 次独立往返：
约额外 12–18 ms

1 次 batch：
只付 1 次主要往返成本
```

所以对**便宜 tactic 主导**的节点，一次 expansion 有希望省 **约 10–15ms**，总 expansion wall time 可能下降约 **20–50%**。

这是**估算，必须用新 benchmark 验证**。

若 6 个候选大量是 `nlinarith ~280ms`，batch 对总耗时帮助就很小；这时真正瓶颈已经是 tactic 本身。

---

### 7.2 deterministic failed-action cache：避免反复验证同一个错误

当前：

```text
(state S, tactic T)
→ Lean 失败
```

如果后续 progressive sampling 再生成完全一样的 T，仍可能再次调用 Lean。

建议：

```text
transition_cache[(state_id, tactic)] =
    success(next_state)
    | parse_failure
    | elaboration_failure
    | tactic_failure
```

其中：

- deterministic failure 可以长期缓存；
- timeout 不建议永久等同“永远失败”，可单独处理。

#### 为什么这项值得做？

“上回轨迹”显示生成重复压力很大：

```text
1280 raw samples
→ 233 canonical candidates
→ 170 真正执行
```

E2 报告：

https://github.com/wufuju2023-cell/10-4-alpha-proof/blob/c3de72599736fcd1b091c4c97c0d41441881b6bf/docs/diversity-mcts/reports/e2-window-audit.md

但要注意：

> 旧 evidence 管线本身已经做过 canonicalization，所以不能把 `1280→233` 直接解释成“新 MCTS 会减少 82% Lean 时间”。

它只能证明：**模型确实会大量重复生成。**

#### 预计节省

最正确的估算法是先记录：

```text
repeat_deterministic_failure_rate
```

如果真实深 MCTS 中：

```text
20% 的 Lean apply
其实是同 state 上以前验证过的 deterministic failure
```

那 cache 就几乎可以直接减少这部分 **20% Lean 调用**。

如果重复率是 40%，理论上就接近减少 40%。

因此这项的收益范围取决于真实轨迹，但风险很低，值得优先实现。

---

### 7.3 去掉无日志时的重复 proof-state pretty-print

当前 Reap `evalTacticStrCore` 在 tactic 执行前会先格式化 proof state，用于 wall-clock log：

https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/Step.lean

即使没有真正写日志，当前路径仍会构造该字符串。

你们自己的 `apply` 成功后又会 `ppGoals`：

```text
pre-pp
→ tactic
→ post-pp
```

短 FATE 上问题不大；真实长上下文可能明显。

建议：

```text
wall-clock detailed logging 关闭
→ 不构造 pre-state pretty-print
```

并将 timing 拆成：

```text
restore
parse
tactic
synthesize/prune
terminal checkProof
post pp
saveState
JSON/FIFO
```

#### 预计节省

目前没有足够数据给可靠百分比。  
合理预期是：**便宜 tactic 上可能是亚毫秒到数毫秒级；重 tactic 上占比很小。**

所以它是值得做的小优化，但不应在没有 profile 前声称能带来大倍数。

---

## 8. 优先级 3：state 生命周期与 timeout

### 8.1 实现 `release`

设计文档有 `release`，261007 实际 server 还没有。

当前：

```lean
Array Tactic.SavedState
```

只增长不释放。

尤其值得注意：

```text
Lean execute tactic
→ save 新 state
→ Python 发现它和已有 sibling state 重复
→ Python 不建新 child
```

此时 Lean 里的临时 SavedState 仍可能留下。

建议先测：

```text
100 / 1k / 5k / 10k states
→ RSS
→ save latency
→ restore latency
→ GC 后 RSS
```

然后优先释放：

```text
duplicate result state
pruned subtree
search 结束后的全部非 root state
```

这项主要是为了**长期稳定和大树搜索**，不一定立即降低小 benchmark 的 wall time。

---

### 8.2 timeout 要从 200–300 秒收紧

当前大致是：

```text
Reap tactic timeout：200s
Python apply timeout：300s
```

对 MCTS 太宽松。

一个 worker 卡 200 秒，相当于很长时间损失一整个 verifier slot。

AlphaProof 原始论文专门提到：

- per-tactic wall-clock limit；
- heartbeat 之外的额外保护；
- 更频繁的资源检查；
- 防 runaway computation。

出处：

https://pmc.ncbi.nlm.nih.gov/articles/PMC12999475/

建议不要直接拍一个极短值，而是先统计：

```text
tactic family
p50 / p90 / p95 / p99
success rate
timeout rate
CPU time share
```

然后比较例如：

```text
5s / 15s / 30s
```

对 solved rate 和 CPU-hours 的影响。

同时补：

```text
watchdog
RSS limit
异常 worker restart
```

---

## 9. 大量短题最有潜力的大改：跨 theorem 常驻 worker

当前一题一个：

```text
lake env lean shell.lean
```

所以每题都重新付：

```text
5.6–7.5s
```

冷启动。

对于简单题，这是当前最大的剩余浪费。

目标是：

```text
worker 0：启动 Lean + Mathlib 一次
          → theorem A
          → theorem B
          → theorem C

worker 1：启动一次
          → theorem D
          → theorem E
...
```

### 对当前 FATE v001 波次的粗略收益

当前实测：

```text
20 题
6 并发
26.6 s
```

因为大部分时间就是 4 波左右的 Lean 冷启动。

如果能做到：

```text
6 个 worker 各自只冷启动一次
之后连续 open 多题
```

并且 theorem open 的额外成本保持较低，那么一个合理的工程目标是：

```text
当前：26.6 s
目标：约 6–10 s
```

即**同类短题波次再快约 2.5–4×**。

> 这是根据当前冷启动和 wave 结构推算的目标，不是已经实测的结果。

对深 MCTS，这项收益会小很多，因为大量 tactic execution 会把 6 秒启动摊薄。

### 要不要为这个迁 Pantograph？

目前我的建议仍然是：

> **先不要。**

你们已经有 `SavedState`、分支搜索和 Reap 语义，迁移会引入新的兼容与对齐工作。

Pantograph 可以作为“跨 theorem persistent RPC”设计参考：

- 官方仓库：  
  https://github.com/leanprover/Pantograph
- Design Rationale：  
  https://github.com/leanprover/Pantograph/blob/dev/doc/rationale.md
- REPL 文档：  
  https://github.com/leanprover/Pantograph/blob/dev/doc/repl.md
- 论文：  
  https://arxiv.org/abs/2410.16429

LeanDojo-v2 目前也在 proof search 中使用 Pantograph RPC：

https://github.com/lean-dojo/LeanDojo-v2

如果以后证明“跨 theorem 常驻”是长期最大瓶颈，再比较：

```text
A. 在现有 Reap 上做 generic theorem server
B. 迁 / 借用 Pantograph
```

哪条工程成本更低。

---

## 10. 重 tactic 主导以后，再考虑 AlphaProof 的 C/native 优化

当前已经看到：

```text
普通 tactic：1–6ms
nlinarith：~280ms
```

所以真实深 MCTS 很可能最终进入：

> IPC 已经不重要，真正 CPU 都在 `linarith/nlinarith/...` 本身。

AlphaProof 原始论文 Methods 的 “Performance and stability considerations” 明确提到：

- 高频关键 Mathlib tactic（论文举例 `linarith`）被编译为 C；
- 对**部分 tactic**，proof-term generation 得到约 **6×** 加速。

出处：

- Nature：  
  https://www.nature.com/articles/s41586-025-09833-y
- PMC 全文：  
  https://pmc.ncbi.nlm.nih.gov/articles/PMC12999475/

注意：

```text
不是整个 verifier 快 6×
不是所有 tactic 都能快 6×
也不是我们现在必须马上做
```

### 什么时候做？

先 profile。

例如如果最终发现：

```text
总 CPU 时间 70%
都花在少数 hot tactic
```

那么即使“热点本身”能做到 6×，按 Amdahl 粗算：

```text
整体 speedup ≈ 1 / (0.30 + 0.70 / 6)
             ≈ 2.4×
```

这时才值得投入底层优化。

如果热点只占 20%，即使热点快很多，对全局收益也有限。

---

## 11. 总体能节省多少？

必须分“相对旧实验”和“相对当前 v0”看。

### 相对旧实验

旧实验：

```text
Lean ≈96.7%
≈25.9s / attempt
≈47min / 一轮评测
```

当前 v0 已经从结构上消除了“每 attempt 整文件重编译”。

当前同机局部 benchmark 已经看到：

```text
整文件 5.54s
vs
稳态会话求解 0.30s
≈18.5×
```

因此**最大的数量级优化其实已经发生了**。

不能把 18.5× 直接无条件外推到所有真实 MCTS，但方向已经被 benchmark 证实。

---

### 相对当前 v0

#### 短题 / 大量 evaluation

最有希望：

```text
跨 theorem 常驻 worker
```

目标：

```text
20 题 / 6 worker
26.6s
→ 约 6–10s
```

即大约再快 **2.5–4×**。

#### 便宜 tactic 为主的深搜索

优先：

```text
apply_batch
+ failed-action cache
+ 去掉不必要 pp
+ ancestor rejection
```

保守地看，若重复失败和 IPC 占比明显，**再降低 20–50% verifier wall time** 是合理目标；但必须由真实多步 workload 的 profiler 验证。

#### 重 tactic 为主的深搜索

如果大部分 CPU 最终集中在：

```text
linarith / nlinarith / aesop / ...
```

那么上述 batch/cache 只能去掉外围浪费。

之后是否还能出现 **2× 以上**整体收益，取决于热点占比和是否能做 AlphaProof 式 native/C 优化。

---

## 12. 下一步建议：不要再猜，做一个真实多步 profiler

目前 FATE v001 的性能测试太“简单题化”。

下一轮建议固定一批真实多步状态，记录每个 `apply`：

```text
restore_ms
pre_pp_ms
parse_ms
tactic_ms
synthesize_ms
check_proof_ms
post_pp_ms
save_state_ms
server_total_ms
python_rtt_ms
```

同时记录：

```text
tactic_head
success/failure/timeout
same-action repeat count
duplicate-state count
ancestor-rejected count
state_count
RSS
```

重点输出：

```text
CPU time by tactic family
CPU time by verifier stage
repeat deterministic failure rate
平均每 expansion 的有效新 state 数
```

然后只需要看一张图，就能决定下一刀：

```text
startup 高
→ 跨 theorem worker

IPC 高
→ apply_batch

重复失败高
→ cache

PP 高
→ lazy / conditional PP

nlinarith 高
→ hot tactic optimization

RSS 随 state 数持续涨
→ release / recycle
```

---

## 13. 我建议的实际执行顺序

### 第一批：现在就做

```text
1. 普通 terminal 恢复 evalTacticStr / final check
2. ancestor-cycle rejection
3. fresh Lean CLI strict final verification
4. deterministic failed-action cache
5. apply_batch
6. 分阶段 profiler
```

### 第二批：真实多步 MCTS 后

```text
7. state release
8. timeout / watchdog / RSS limit
9. 重新扫描 1/2/4/8/12 worker
```

### 第三批：根据 profile 决定

```text
10. 跨 theorem persistent worker
11. 是否需要 Pantograph
12. hot tactic native/C optimization
```

如果后续 workload 主要是成千上万道短课程题，那么第 10 项应提前；如果主要是少量难题、每题数千节点，则第 12 项可能更早变重要。

---

## 14. 最终判断

我对当前路线的判断是：

> **方向正确，不需要推倒重来。**

261007 这一版已经解决了最昂贵的结构性问题：

```text
反复整文件编译
→ SavedState 增量验证
```

现在要做的是把 verifier 从“已经很快”继续变成“几乎不做任何重复工作”：

```text
不重复验证同一失败 action
不重复做 K 次 IPC
不走祖先环
不保留废弃 state
不做无意义 pp
不让异常 tactic 卡住 worker
```

同时保留：

```text
低频新 tactic 仍然允许探索
```

这点很重要，因为 E2 已经显示：

```text
27/49 verified tactic
在 64 次采样里只出现 ≤2 次
```

所以**不能为了省 CPU 就简单只验高 prior / 高频 tactic**。

正确的优化方向是：

> **去掉重复计算，而不是去掉探索本身。**

---

## 参考资料

### 本项目

1. CPU server 当前仓库  
   https://github.com/wufuju2023-cell/lean-mcts-cpu-server

2. 261007 benchmark（固定 commit）  
   https://github.com/wufuju2023-cell/lean-mcts-cpu-server/blob/f707a11a80c24c34d405fdd344255f2394fc21f4/docs/BENCH-2026-10-07.md

3. 当前 `lmc_preamble.lean`  
   https://github.com/wufuju2023-cell/lean-mcts-cpu-server/blob/f707a11a80c24c34d405fdd344255f2394fc21f4/lean/lmc_preamble.lean

4. 当前 Python MCTS  
   https://github.com/wufuju2023-cell/lean-mcts-cpu-server/blob/f707a11a80c24c34d405fdd344255f2394fc21f4/lmc/mcts.py

5. E2 “上回轨迹”审计  
   https://github.com/wufuju2023-cell/10-4-alpha-proof/blob/c3de72599736fcd1b091c4c97c0d41441881b6bf/docs/diversity-mcts/reports/e2-window-audit.md

6. 旧实验耗时与新 server benchmark 计划  
   https://github.com/wufuju2023-cell/10-4-alpha-proof/blob/c3de72599736fcd1b091c4c97c0d41441881b6bf/docs/new-python-version-mcts-plan/08-testing-and-load-bench.md

### AlphaProof / Reap

7. AlphaProof 原始 Nature 论文  
   https://www.nature.com/articles/s41586-025-09833-y

8. AlphaProof 开放全文  
   https://pmc.ncbi.nlm.nih.gov/articles/PMC12999475/

9. Reap `State.lean` @ `0090d73c`  
   https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/State.lean

10. Reap `Step.lean` @ `0090d73c`  
    https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/Step.lean

11. Reap `TreeSearch.lean` @ `0090d73c`  
    https://github.com/IQuestLab/reap/blob/0090d73c/Reap/Tactic/TreeSearch.lean

### 其他公开参考

12. Pantograph  
    https://github.com/leanprover/Pantograph

13. Pantograph paper  
    https://arxiv.org/abs/2410.16429

14. LeanDojo-v2  
    https://github.com/lean-dojo/LeanDojo-v2

15. *Keep the Proof State Live: Snapshotting for Efficient Tactic Search in Lean 4*  
    https://arxiv.org/abs/2605.25556
