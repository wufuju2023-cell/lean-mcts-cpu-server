"""Scripted policies / values for benchmark problems (no GPU required)."""

from __future__ import annotations

from typing import Callable

# Pell course problem (`CodexMathFive.PellSmoke.CourseInvariant`):
# the recorded successful script is `intro x y h; simp only [step]; nlinarith [h]`.
# A fixed candidate list works without reading the goal text: wrong candidates
# fail and simply never become children.
PELL_CANDIDATES: list[tuple[str, float]] = [
    ("intro x y h", -0.02),
    ("simp only [step]", -0.02),
    ("nlinarith [h]", -0.02),
    ("trivial", -1.5),
]


def pell_policy(_goals: list[str]) -> list[tuple[str, float]]:
    return PELL_CANDIDATES


def zero_value(_goals: list[str]) -> float:
    return 0.0


def make_policy(candidates: list[tuple[str, float]]) -> Callable[[list[str]], list[tuple[str, float]]]:
    def policy(_goals: list[str]) -> list[tuple[str, float]]:
        return candidates
    return policy
