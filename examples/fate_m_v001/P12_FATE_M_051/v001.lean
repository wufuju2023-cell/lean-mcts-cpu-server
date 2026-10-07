import Mathlib

namespace FateCurriculum

/-- FATE-M #51, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_051_v001 {G : Type*} [Group G] (a b : G) (h : (a * b) ^ 2 = a ^ 2 * b ^ 2)
    (curriculum_target : (a * b = b * a)) :
    (a * b = b * a) := by
  sorry

end FateCurriculum
