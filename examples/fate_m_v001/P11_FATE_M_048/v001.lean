import Mathlib

namespace FateCurriculum

/-- FATE-M #48, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_048_v001 {G : Type*} [Group G] (a b : G) (h : a * b = b * a⁻¹)
    (curriculum_target : (b * a = a⁻¹ * b)) :
    (b * a = a⁻¹ * b) := by
  sorry

end FateCurriculum
