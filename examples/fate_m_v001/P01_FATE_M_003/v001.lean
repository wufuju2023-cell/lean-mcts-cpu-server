import Mathlib

namespace FateCurriculum

/-- FATE-M #3, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_003_v001 {G H K : Type*} [Group G] [Group H] [Group K]
    (f : G →* H) (g : H →* K) (hf : Function.Surjective f) (hg : Function.Surjective g)
    (curriculum_target : (Function.Surjective (g.comp f))) :
    (Function.Surjective (g.comp f)) := by
  sorry

end FateCurriculum
