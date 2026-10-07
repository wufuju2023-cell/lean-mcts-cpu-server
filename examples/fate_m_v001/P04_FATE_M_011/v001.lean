import Mathlib

namespace FateCurriculum

/-- FATE-M #11, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_011_v001 {R : Type*} [Ring R] (a b c : R)
    (curriculum_target : (a * (b - c) = a * b - a * c ∧ (b - c) * a = b * a - c * a)) :
    (a * (b - c) = a * b - a * c ∧ (b - c) * a = b * a - c * a) := by
  sorry

end FateCurriculum
