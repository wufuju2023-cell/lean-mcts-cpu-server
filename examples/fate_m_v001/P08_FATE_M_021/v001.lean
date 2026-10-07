import Mathlib

namespace FateCurriculum

/-- FATE-M #21, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_021_v001 {F : Type*} [Field F] {a : Fˣ} {b : F}
    (curriculum_target : (∃! x, a * x + b = 0)) :
    (∃! x, a * x + b = 0) := by
  sorry

end FateCurriculum
