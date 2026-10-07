import Mathlib

namespace FateCurriculum

/-- FATE-M #61, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_061_v001 {G : Type*} [Group G]
    (M : Subgroup G) [hM : M.Normal] (N : Subgroup G) [hN: N.Normal]
    (curriculum_target : ((M ⊓ N).Normal)) :
    ((M ⊓ N).Normal) := by
  sorry

end FateCurriculum
