import Mathlib

namespace FateCurriculum

/-- FATE-M #14, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_014_v001 {R : Type*} [Ring R] [IsDomain R] (a : R) (n : ℕ)
    (eq : a ^ n = 0)
    (curriculum_target : (a = 0)) :
    (a = 0) := by
  sorry

end FateCurriculum
