import Mathlib

namespace FateCurriculum

/-- FATE-M #4, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_004_v001 {G G' : Type*} [Group G] [Group G'] (f : G →* G') {a b : G}
    (curriculum_target : ((a * b ∈ f.ker)  ↔ (b * a ∈ f.ker))) :
    ((a * b ∈ f.ker)  ↔ (b * a ∈ f.ker)) := by
  sorry

end FateCurriculum
