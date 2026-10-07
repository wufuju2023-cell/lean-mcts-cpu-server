import Mathlib

namespace FateCurriculum

/-- FATE-M #68, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_068_v001 {G : Type*} [Group G] (a : G)
    (curriculum_target : (orderOf a = orderOf (a⁻¹))) :
    (orderOf a = orderOf (a⁻¹)) := by
  sorry

end FateCurriculum
