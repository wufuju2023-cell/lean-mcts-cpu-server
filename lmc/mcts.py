"""Python MCTS over the Lean session backend.

对齐官方 PUCT 语义（与 `alphaproof/mcts` 同一套超参 / 更新规则）：
- c_base=3200, c_init=0.001, tau=200, ps_c=0.01, ps_alpha=0.6, c_AND=64, c_pen=32, gamma=0.99
- Q = gamma^(-1 - V)；未访问子 Q = V(s) - c_pen；AND 探索项 × c_AND
- 渐进采样只增不减；同战术先验合并、同状态合并
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, Optional

OR = "OR"
AND = "AND"


@dataclass
class SearchConfig:
    num_samples: int = 6
    c_base: float = 3200.0
    c_init: float = 0.001
    visit_discount: float = 0.99
    prior_temperature: float = 200.0
    ps_c: float = 0.01
    ps_alpha: float = 0.6
    c_and: float = 64.0
    unvisited_penalty: float = 32.0
    max_nodes: int = 64
    max_steps: int = 64


@dataclass
class Edge:
    action: str
    prior: float = 0.0
    is_focus: bool = False
    num_visit: int = 0
    value: float = 0.0

    @property
    def step_cost(self) -> float:
        return 0.0 if self.is_focus else 1.0


@dataclass
class Node:
    state: Optional[int]
    state_key: str
    state_repr: str = ""
    to_play: str = OR
    terminal: bool = False
    solved: bool = False
    is_optimal: bool = False
    value_target: Optional[float] = None
    net_value: float = 0.0
    value_sum: float = 0.0
    num_visit: int = 0
    num_evaluations: int = 0
    parent: Optional["Node"] = None
    parent_action: Optional[str] = None
    children: dict[str, "Node"] = field(default_factory=dict)
    edges: dict[str, "Edge"] = field(default_factory=dict)

    def value(self) -> float:
        return self.value_sum / self.num_visit if self.num_visit else 0.0

    def expanded(self) -> bool:
        return bool(self.children)

    def add_child(self, action: str, child: "Node", prior: float, is_focus: bool = False) -> None:
        self.children[action] = child
        self.edges[action] = Edge(action=action, prior=prior, is_focus=is_focus)
        child.parent = self
        child.parent_action = action

    def refresh_solved(self) -> None:
        if self.terminal:
            self.solved = True
            return
        if not self.children:
            return
        if self.to_play == OR:
            self.solved = any(c.solved for c in self.children.values())
        else:
            self.solved = all(c.solved for c in self.children.values())


def backprop_towards_min(node: Node) -> float:
    values = [c.value() for c in node.children.values() if not c.solved and c.num_visit > 0]
    return min(values) if values else 1.0


@dataclass
class SearchResult:
    root: Node
    solved: bool
    nodes_created: int
    simulations: int
    best_script: list[str] = field(default_factory=list)
    apply_rtt_ms: list[float] = field(default_factory=list)
    apply_lean_ms: list[float] = field(default_factory=list)

    def summary(self) -> dict:
        return {
            "solved": self.solved,
            "nodes_created": self.nodes_created,
            "simulations": self.simulations,
            "best_script": self.best_script,
            "applies": len(self.apply_rtt_ms),
        }


class MCTS:
    def __init__(
        self,
        session,
        policy: Callable[[list[str]], list[tuple[str, float]]],
        value: Optional[Callable[[list[str]], float]] = None,
        config: Optional[SearchConfig] = None,
    ) -> None:
        self.session = session
        self.policy = policy
        self.value = value
        self.config = config or SearchConfig()
        self._nodes_created = 0
        self._result: Optional[SearchResult] = None

    # ------------------------------------------------------------------ #
    def search(self, root_state: int, root_repr: str = "") -> SearchResult:
        cfg = self.config
        self._nodes_created = 1
        if not root_repr:
            g = self.session.goals(root_state)
            root_repr = "\n".join(g.get("goals", []))
        root = Node(state=root_state, state_key=f"root#{root_state}", state_repr=root_repr)
        result = SearchResult(root=root, solved=False, nodes_created=0, simulations=0)
        self._result = result
        sims = 0

        for sim in range(cfg.max_steps):
            if root.solved:
                break
            if self._nodes_created >= cfg.max_nodes:
                break
            sims = sim + 1
            path_nodes: list[Node] = [root]
            path_edges: list[Edge] = []
            node = root
            while node.expanded() and not node.terminal and not self._progressive_sample(node):
                child = self._select(node)
                if child is None:
                    break
                assert child.parent_action is not None
                path_edges.append(node.edges[child.parent_action])
                path_nodes.append(child)
                node = child
            if node.terminal:
                leaf_value = 0.0
            else:
                leaf_value = self._expand(node)
            self._backprop(path_nodes, path_edges, leaf_value)
            for n in path_nodes:
                n.refresh_solved()

        root.refresh_solved()
        if root.solved:
            self._mark_optimal(root)
            self._compute_value_target_iter(root)
            result.best_script = self._collect_script(root)
        result.solved = root.solved
        result.nodes_created = self._nodes_created
        result.simulations = sims
        return result

    # ------------------------------------------------------------------ #
    def puct_scores(self, node: Node) -> dict[str, float]:
        cfg = self.config
        n = float(node.num_visit)
        c = cfg.c_init + math.log((n + cfg.c_base + 1) / cfg.c_base)
        total_mass = sum(e.prior for e in node.edges.values()) or 1.0
        parent_value = node.value()
        scores: dict[str, float] = {}
        for action, child in node.children.items():
            edge = node.edges[action]
            p = edge.prior / total_mass
            if edge.num_visit > 0 or child.num_visit > 0:
                value = child.value() - edge.step_cost
                q = cfg.visit_discount ** (-1.0 - value)
            else:
                q = cfg.visit_discount ** (-1.0 - (parent_value - cfg.unvisited_penalty))
            if node.to_play == AND:
                q = float("-inf") if child.solved else 1.0 - q
            u = c * p * math.sqrt(n) / (edge.num_visit + 1)
            if node.to_play == AND:
                u *= cfg.c_and
            scores[action] = q + u
        return scores

    def _select(self, node: Node) -> Optional[Node]:
        scores = self.puct_scores(node)
        if not scores:
            return None
        best = max(scores.items(), key=lambda kv: kv[1])[0]
        return node.children[best]

    def _progressive_sample(self, node: Node) -> bool:
        cfg = self.config
        return (
            node.to_play == OR
            and node.num_evaluations <= cfg.ps_c * (node.num_visit ** cfg.ps_alpha)
        )

    # ------------------------------------------------------------------ #
    def _expand(self, node: Node) -> float:
        cfg = self.config
        if node.to_play == AND and node.children:
            return node.value()
        assert node.state is not None
        tactics = self.policy(node.state_repr.splitlines()) or []
        node.num_evaluations += 1
        net = float(self.value(node.state_repr.splitlines())) if self.value else 0.0
        node.net_value = net
        node.value_sum += net
        node.num_visit += 1

        for action, logprob in list(tactics)[: cfg.num_samples]:
            if not isinstance(action, str) or not action.strip():
                continue
            prior = math.exp(float(logprob) / cfg.prior_temperature)
            if action in node.children:
                node.edges[action].prior += prior
                continue
            res = self.session.apply(node.state, action)
            if res.rtt_ms is not None and self._result is not None:
                self._result.apply_rtt_ms.append(res.rtt_ms)
                if res.elapsed_ms is not None:
                    self._result.apply_lean_ms.append(res.elapsed_ms)
            if not res.ok:
                continue
            dup = next(
                (k for k, c in node.children.items() if c.state_key == res.state_key),
                None,
            )
            if dup is not None:
                node.edges[dup].prior += prior
                continue
            child = Node(
                state=res.state,
                state_key=res.state_key or f"{node.state_key}::{action}",
                state_repr="\n".join(res.goals),
                to_play=AND if res.num_goals > 1 else OR,
                terminal=res.closed,
                solved=res.closed,
            )
            node.add_child(action, child, prior)
            self._nodes_created += 1
            if child.to_play == AND and child.state is not None:
                n = res.num_goals
                for i in range(n):
                    f = self.session.focus(child.state, i)
                    if not f.ok or f.state is None:
                        continue
                    fnode = Node(
                        state=f.state,
                        state_key=f.state_key,
                        state_repr="\n".join(f.goals),
                        to_play=OR,
                    )
                    child.add_child(f"focus_goal {i}", fnode, 1.0 / n, is_focus=True)
                    self._nodes_created += 1
                child.refresh_solved()
        node.refresh_solved()
        return net

    # ------------------------------------------------------------------ #
    def _backprop(self, path_nodes: list[Node], path_edges: list[Edge], leaf_value: float) -> None:
        value = leaf_value
        for i in range(len(path_nodes) - 1, 0, -1):
            parent = path_nodes[i - 1]
            edge = path_edges[i - 1]
            value = value - edge.step_cost
            edge.num_visit += 1
            edge.value += value
            parent.value_sum += value
            parent.num_visit += 1
            parent.refresh_solved()
            if parent.to_play == AND:
                value = backprop_towards_min(parent)

    # ------------------------------------------------------------------ #
    @staticmethod
    def _mark_optimal(node: Node) -> None:
        node.is_optimal = True
        if node.terminal:
            return
        if node.to_play == OR:
            for child in node.children.values():
                if child.solved:
                    child.is_optimal = True
                    MCTS._mark_optimal(child)
                    return
        else:
            for child in node.children.values():
                if child.solved:
                    child.is_optimal = True
                    MCTS._mark_optimal(child)

    @staticmethod
    def _collect_script(node: Node) -> list[str]:
        if node.terminal:
            return []
        script: list[str] = []
        if node.to_play == OR:
            for action, child in node.children.items():
                if child.is_optimal:
                    if not action.startswith("focus_goal"):
                        script.append(action)
                    script.extend(MCTS._collect_script(child))
                    break
        else:
            for child in node.children.values():
                if child.is_optimal:
                    script.extend(MCTS._collect_script(child))
        return script

    # ------------------------------------------------------------------ #
    # 值目标（N-02 显式栈迭代版；OR: -1+子；AND: min；terminal: 0）
    @staticmethod
    def _compute_value_target_iter(root: Node) -> float:
        stack: list[tuple[Node, bool]] = [(root, False)]
        while stack:
            node, done = stack.pop()
            if not done:
                if node.terminal:
                    node.value_target = 0.0
                    continue
                stack.append((node, True))
                if node.to_play == OR:
                    child = next((c for c in node.children.values() if c.is_optimal), None)
                    if child is not None:
                        stack.append((child, False))
                else:
                    for child in reversed(list(node.children.values())):
                        stack.append((child, False))
            else:
                if node.to_play == OR:
                    child = next((c for c in node.children.values() if c.is_optimal), None)
                    node.value_target = -1.0 + (child.value_target if child is not None and child.value_target is not None else 0.0)
                else:
                    vals = [c.value_target for c in node.children.values() if c.value_target is not None]
                    node.value_target = min(vals) if vals else 0.0
        return root.value_target or 0.0
