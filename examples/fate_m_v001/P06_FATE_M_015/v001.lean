import Mathlib

namespace FateCurriculum

/-- FATE-M #15, curriculum variant 1/200; tier 1: direct_target. -/
theorem fate_m_015_v001 {R : Type*} [Ring R] {x y z : R} (hx : x ≠ 0) (hy : x * y = 1)
    (hz : z * x = 1)
    (curriculum_target : (y = z)) :
    (y = z) := by
  sorry

end FateCurriculum
