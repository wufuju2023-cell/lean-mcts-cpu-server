import Mathlib

namespace FateCurriculum

/-- FATE-M #9, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_009_v001 {G H : Type*} [Group G] [Group H] {f : G →* H} {a : G}
    (h : orderOf (f a) = 0)
    (curriculum_target : (orderOf a = 0)) :
    (orderOf a = 0) := by
  sorry

end FateCurriculum
