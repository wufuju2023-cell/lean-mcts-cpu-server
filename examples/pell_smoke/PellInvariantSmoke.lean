/-
  佩尔课程第一课（CourseInvariant）的真实内核求解冒烟。

  配上脚本化 policy（返回一步证明）即可得到 solved: true：
      python3 scripts/scripted_policy_server.py --port 18081 \
          --tactic "intro x y h; simp only [step]; nlinarith [h]"
  对应 manifest：manifest.invariant.jsonl
-/
import ReapRuntime

set_option reap.policy_endpoint "http://127.0.0.1:18081/policy/v1"
set_option reap.value_endpoint "http://127.0.0.1:18081/value/v1"
set_option reap.num_samples 2
set_option reap.num_premises 0
set_option reap.max_goals 8
set_option reap.max_steps 8

namespace CodexMathFive.PellSmoke

def step (p : ℕ × ℕ) : ℕ × ℕ :=
  (3 * p.1 + 4 * p.2, 2 * p.1 + 3 * p.2)

/-- CourseInvariant：变换保持 Pell 方程（原题课程第一课）。 -/
def CourseInvariant : Prop :=
  ∀ x y : ℕ, x ^ 2 = 2 * y ^ 2 + 1 →
    (step (x, y)).1 ^ 2 = 2 * (step (x, y)).2 ^ 2 + 1

theorem pell_invariant_smoke : CourseInvariant := by
  reapTrainingMCTS

end CodexMathFive.PellSmoke
