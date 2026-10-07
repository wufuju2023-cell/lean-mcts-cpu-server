import Mathlib

namespace FateCurriculum

/-- FATE-M #52, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_052_v001 {G : Type*} [Group G] (a b c : G) (h : a * b * c = 1)
    (curriculum_target : (b * c * a = 1)) :
    (b * c * a = 1) := by
  sorry

end FateCurriculum
