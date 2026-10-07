module
public meta import Lean
public meta import Reap.Options
public meta import Reap.PremiseSelection.API
public meta import Reap.Tactic.State
public meta import Reap.Tactic.Step
public meta import Reap.Tactic.WallClock
public meta import Reap.TreeSearch.MCTS
public meta import Reap.TreeSearch.BestFirst
open Lean Meta Elab Tactic TreeSearch
open Reap.WallClock

public meta section

namespace Reap.TreeSearch

def writeRawTree (path : String) (obj : Json) : IO Unit := do
  if !path.isEmpty then
    IO.FS.withFile path .write fun h =>
      h.putStrLn obj.compress

def getGoalTypes : TacticM (Option (Array Expr)) := do
  let goals ← getUnsolvedGoals
  let mut goalTypes := #[]
  for g in goals do
    let t ← g.getTypeCleanup
    if t.hasExprMVar then
      return none
    else
      goalTypes := goalTypes.push t
  return some goalTypes

def goalContainsExprMVar (goal : MVarId) : TacticM Bool := goal.withContext do
  let target ← goal.getTypeCleanup
  if target.hasExprMVar then
    return true
  for localDecl in ← getLCtx do
    let type ← instantiateMVars localDecl.type
    if type.hasExprMVar then
      return true
    if let some value := localDecl.value? then
      let value ← instantiateMVars value
      if value.hasExprMVar then
        return true
  return false

def anyGoalContainsExprMVar (goals : List MVarId) : TacticM Bool := do
  for goal in goals do
    if ← goalContainsExprMVar goal then
      return true
  return false

def unifyTypes (t₁ t₂ : Array Expr) : TacticM Bool := do
  let mut ret := true
  let mut t₂' := t₂
  for t in t₁ do
    if let some i ← t₂'.findIdxM? fun t' => Meta.isDefEqGuarded t t' then
      t₂' := t₂'.eraseIdx! i
    else
      ret := false
      break
  return ret

abbrev PolicyValueEval := List MVarId → MetaM (Float × Array (String × Array PremiseSelectionResult × Float))

structure MCTSProgress where
  visitedNodes : Nat
  maxNodes : Nat
  step : Nat
  maxSteps : Nat
  goalType : String
  done : Bool
  solved : Bool
  status : String
deriving Inhabited

abbrev ProgressReporter := MCTSProgress → TacticM Unit

/-- Optional synchronous observation. JSON contains no mutable search state.
Callbacks run with the tactic state restored on success and on exceptions. -/
abbrev MCTSObserver := Json → TacticM Unit

namespace MCTSProgress

def initial (maxNodes maxSteps : Nat) : MCTSProgress where
  visitedNodes := 0
  maxNodes := maxNodes
  step := 0
  maxSteps := maxSteps
  goalType := "starting"
  done := false
  solved := false
  status := "running"

end MCTSProgress

structure SearchHyperparameters where
  cBase : Float
  cInit : Float
  visitDiscount : Float
  priorTemperature : Float
  progressiveSamplingC : Float
  progressiveSamplingAlpha : Float
  cAnd : Float
  unvisitedPenalty : Float

def scaledNatToFloat (n : Nat) : Float :=
  n.toFloat / 1000.0

namespace SearchHyperparameters

def fromOptions (opts : Options) : SearchHyperparameters := {
  cBase := reap.c_base.get opts |>.toFloat
  cInit := scaledNatToFloat <| reap.c_init.get opts
  visitDiscount := scaledNatToFloat <| reap.visit_discount.get opts
  priorTemperature := reap.prior_temperature.get opts |>.toFloat
  progressiveSamplingC := scaledNatToFloat <| reap.progressive_sampling_c.get opts
  progressiveSamplingAlpha := scaledNatToFloat <| reap.progressive_sampling_alpha.get opts
  cAnd := reap.c_and.get opts |>.toFloat
  unvisitedPenalty := reap.unvisited_penalty.get opts |>.toFloat
}

end SearchHyperparameters

namespace MCTS
inductive NodeKind where
  | orNode
  | andNode
deriving BEq, Inhabited

instance : ToJson NodeKind where
  toJson
  | .orNode => "OR"
  | .andNode => "AND"

structure NodeData where
  state : Tactic.SavedState
  key : StateKey
  toPlay : NodeKind
  partialGoal : Option MVarId
  isSolved : Bool
  valueSum : Float
  numVisit : Nat
  numEvaluations : Nat

namespace NodeData
def fromState (toPlay := NodeKind.orNode) (partialGoal : Option MVarId := none) : TacticM NodeData := do
  pure {
    state := ← Tactic.saveState
    key := ← stateKey
    toPlay
    partialGoal
    isSolved := (← getUnsolvedGoals).isEmpty
    valueSum := 0.0
    numVisit := 0
    numEvaluations := 0
  }

def value (node : NodeData) : Float :=
  if node.numVisit == 0 then 0.0 else node.valueSum / node.numVisit.toFloat

def restore (node : NodeData) : TacticM Unit :=
  node.state.restore

def isTerminal (node : NodeData) : TacticM Bool := do
  node.restore
  return (← getUnsolvedGoals).isEmpty

def proofCheckContext (node : NodeData) (ctx : ProofCheckContext) : ProofCheckContext :=
  match node.partialGoal with
  | some goal => { ctx with originalGoals := [goal] }
  | none => ctx

end NodeData

structure EdgeData where
  tacticStr : String
  premise : Array PremiseSelectionResult
  probability : Float
  value : Float
  numVisit : Nat := 0
  isFocus : Bool := false
  focusIndex : Nat := 0
deriving ToJson

abbrev NodeType := Node NodeData (EdgeData × NodeData)

abbrev SearchM := IndexedTreeT NodeData EdgeData TacticM

/-- Lazily construct an event only when observation is enabled. The observer
cannot access the StateT tree, and rendering/callback effects on Lean are undone. -/
def observe? (observer? : Option MCTSObserver) (record : TacticM Json) : SearchM Unit := do
  if let some observer := observer? then
    liftM (show TacticM Unit from do
      let saved ← Tactic.saveState
      try
        observer (← record)
      finally
        saved.restore (restoreInfo := true))

def getNode! (nodeIdx : Nat) : SearchM (Node NodeData (EdgeData × Nat)) := do
  let nodes ← get
  let some node := nodes[nodeIdx]? | throwError "MCTS node index out of bounds: {nodeIdx}"
  return node

def getChild! (node : Node NodeData (EdgeData × Nat)) (childPos : Nat) :
    SearchM (EdgeData × Nat) := do
  let some child := node.children[childPos]?
    | throwError "MCTS child index out of bounds: requested {childPos}, node has {node.children.size} children"
  return child

def nodeSolved (node : NodeType) : Bool :=
  match node.data.toPlay with
  | .orNode => node.data.isSolved || node.children.any fun (_, child) => child.isSolved
  | .andNode => node.data.isSolved || (!node.children.isEmpty && node.children.all fun (_, child) => child.isSolved)

def refreshNodeSolved (nodeIdx : Nat) : SearchM Unit := do
  let nodeRef ← getNode! nodeIdx
  let node ← resolve nodeRef
  setAtT nodeIdx { nodeRef with data := { nodeRef.data with isSolved := nodeSolved node } }

def focusProbability (numGoals : Nat) : Float :=
  if numGoals == 0 then 0.0 else 1.0 / numGoals.toFloat

def pushFocusChildren (nodeIdx : Nat) (node : NodeData) : SearchM Unit := do
  node.state.restore
  let goals := (← getUnsolvedGoals).toArray
  let probability := focusProbability goals.size
  for (goal, i) in goals.zipIdx do
    node.state.restore
    setGoals [goal]
    let childData ← NodeData.fromState (partialGoal := some goal)
    discard <| pushChildT nodeIdx {
      tacticStr := s!"focus_goal {i}"
      premise := #[]
      probability
      value := 0.0
      isFocus := true
      focusIndex := i
    } childData
  node.state.restore

def childKindAfterTactic : TacticM NodeKind := do
  let goals ← getUnsolvedGoals
  if goals.length <= 1 then
    return .orNode
  if ← goals.anyM goalContainsExprMVar then
    return .orNode
  return .andNode

def updateDuplicateChild (nodeIdx childPos : Nat) (childData : NodeData) : SearchM Unit := do
  let nodeRef ← getNode! nodeIdx
  if let some (_, childIdx) := nodeRef.children[childPos]? then
    let childRef ← getNode! childIdx
    setAtT childIdx { childRef with data := { childRef.data with isSolved := childRef.data.isSolved || childData.isSolved } }

def visitNode (ctx : ProofCheckContext) (evalPolicyValue : PolicyValueEval)
    (ancestorKeys : Std.HashSet StateKey)
    (nodeIdx : Nat) (node : NodeType)
    (observer? : Option MCTSObserver := none) (step := 0) : SearchM Float := do
  if node.data.toPlay == .andNode then
    if node.children.isEmpty then
      pushFocusChildren nodeIdx node.data
      refreshNodeSolved nodeIdx
    return node.data.value

  node.data.state.restore
  let g ← getUnsolvedGoals
  let (p', tactics) ← if g.isEmpty then
    pure (0.0, #[])
  else
    evalPolicyValue g
  let data' := {
    node.data with
      valueSum := node.data.valueSum + p'
      numVisit := node.data.numVisit + 1
      numEvaluations := node.data.numEvaluations + 1
  }
  modifyAtT nodeIdx fun node => { node with data := data' }

  let opts ← getOptions
  let heartbeats := reap.heartbeats.get opts
  let priorTemperature := reap.prior_temperature.get opts |>.toFloat
  for ((t, ps, prior), candidateIdx) in tactics.zipIdx do
    observe? observer? do
      node.data.state.restore
      let goalState := toString (← TacticGenerator.Meta.ppProofState (← getUnsolvedGoals))
      return json%{
        kind: "generation", step: $step, node_index: $nodeIdx,
        generation_index: $(node.data.numEvaluations), candidate_index: $candidateIdx,
        goal_state: $goalState, state_key: $(node.data.key), node_kind: $(node.data.toPlay),
        tactic: $t, ps: $ps, prompt: $(TacticGenerator.mkPrompt goalState ps),
        raw_logprob: $prior, search_value: $p'
      }
    node.data.state.restore
    let result ←
      match node.data.partialGoal with
      | some _ =>
          -- A focused AND-child may close a goal using declarations whose
          -- proof obligations are sibling AND-children. The whole replay is
          -- final-checked after every child is solved.
          evalTacticStrNoFinalCheck (node.data.proofCheckContext ctx) t heartbeats
      | none =>
          evalTacticStr (node.data.proofCheckContext ctx) t heartbeats
    let mut observedChild : Option Nat := none
    let mut disposition := if result.isOk then "ancestor_rejected" else "eval_rejected"
    if result.isOk then
      let probability := (prior / priorTemperature).exp
      let childKind ← childKindAfterTactic
      let childData ← NodeData.fromState childKind node.data.partialGoal
      if !ancestorKeys.contains childData.key then
        let parentRef ← getNode! nodeIdx
        let parent ← resolve parentRef
        if let some ((e, c), childPos) := parent.children.zipIdx.find? fun ((e, c), _) => e.tacticStr == t || c.key == childData.key then
          observedChild := parentRef.children[childPos]?.map Prod.snd
          disposition := "merged"
          let e' := { e with probability := e.probability + probability }
          updateDuplicateChild nodeIdx childPos childData
          modifyAtT nodeIdx fun node => {
            node with
              data := { node.data with isSolved := node.data.isSolved || c.isSolved || childData.isSolved }
              children := node.children.modify childPos fun (_, c) => (e', c)
          }
        else
          let childIdx ← pushChildT nodeIdx {
            tacticStr := t
            premise := ps
            probability
            value := 0.0
          } childData
          observedChild := some childIdx
          disposition := "created"
          if childData.toPlay == .andNode then
            pushFocusChildren childIdx childData
            refreshNodeSolved childIdx
    observe? observer? do
      return json%{
        kind: "eval", step: $step, node_index: $nodeIdx,
        generation_index: $(node.data.numEvaluations), candidate_index: $candidateIdx,
        tactic: $t, eval_result: $result, child_index: $observedChild,
        disposition: $disposition, partial_goal: $(node.data.partialGoal.isSome)
      }
  refreshNodeSolved nodeIdx
  return p'

structure CQU where
  c : Float
  Q : Float
  U : Float
deriving Inhabited, ToJson

def edgeStepCost (edge : EdgeData) : Float :=
  if edge.isFocus then 0.0 else 1.0

def computePUCTScores (params : SearchHyperparameters)
    (node : NodeType) : Array (Float × CQU) :=
  -- exploration factor
  let N := node.data.numVisit.toFloat
  let c := params.cInit + Float.log ((N + params.cBase + 1) / params.cBase)
  let totalMass := (node.children.map fun (e, _) => e.probability).sum
  let parentValue :=
    if node.data.numVisit > 0 then
      node.data.valueSum / node.data.numVisit.toFloat
    else
      0.0
  node.children.map fun (e, n) =>
    let valueScore :=
      if n.numVisit > 0 then
        let value := n.value - edgeStepCost e
        params.visitDiscount.pow (-1.0 - value)
      else
        -- AlphaProof: V(s,a) = V_net(s) - c_pen for unvisited children (Table 3: 32).
        params.visitDiscount.pow (-1.0 - (parentValue - params.unvisitedPenalty))
    let Q := match node.data.toPlay with
      | .orNode => valueScore
      | .andNode => if n.isSolved then -Float.inf else 1 - valueScore
    let p := e.probability / totalMass
    let andMultiplier := match node.data.toPlay with
      | .andNode => params.cAnd
      | .orNode => 1.0
    let U := andMultiplier * c * p * N.sqrt / (e.numVisit.toFloat + 1)
    let score := Q + U
    (score, { c := c, Q := Q, U := U })

def shouldProgressiveSample (params : SearchHyperparameters) (node : NodeData) : Bool :=
  node.toPlay == .orNode && node.numEvaluations.toFloat <=
    params.progressiveSamplingC * Float.pow node.numVisit.toFloat params.progressiveSamplingAlpha

def ppNodeData (node : NodeData) : TacticM Json := do
  node.state.restore
  let pp ← (← getUnsolvedGoals).mapM fun g => do return toString (← Meta.ppGoal g)
  return json%{
    state: $(pp),
    toPlay: $(node.toPlay),
    isPartial: $(node.partialGoal.isSome),
    isSolved: $(node.isSolved),
    valueSum: $(node.valueSum),
    numVisit: $(node.numVisit),
    numEvaluations: $(node.numEvaluations)
  }

def ppNode (params : SearchHyperparameters) (arr : Array (Node NodeData (EdgeData × Nat)))
    (node : Node NodeData (EdgeData × Nat)) : TacticM Json := do
  let children ← node.children.mapM fun (e, i) => do
    let some x := arr[i]? | throwError "MCTS node child index out of bounds while rendering raw tree: {i}"
    return (e, x.data)
  let scores := computePUCTScores params { data := node.data, children := children }
  let ppChildren := node.children.zip scores |>.map fun ((e, i), (score, cqu)) => json%{
    edge: $e,
    extra: {
      score: $score,
      c: $cqu.c,
      Q: $cqu.Q,
      U: $cqu.U
    },
    childIndex: $i
  }
  return json%{
    data: $(← ppNodeData node.data),
    children: $ppChildren
  }

/-- An iteration boundary: the callback returns before this same tree continues.
root_is_solved is a search flag, not a substitute for final replay/checkProof. -/
def reportCheckpoint? (observer? : Option MCTSObserver) (params : SearchHyperparameters)
    (step : Nat) : SearchM Unit := do
  let nodes ← get
  observe? observer? do
    let ppNodes ← nodes.mapM (ppNode params nodes)
    return json%{
      kind: "checkpoint", step: $step, gamma: $(params.visitDiscount),
      root_is_solved: $((nodes[0]?.map fun n => n.data.isSolved).getD false),
      tree: { root_index: 0, nodes: $ppNodes }
    }

def selectChild (params : SearchHyperparameters) (node : NodeType) : Option Nat := do
  if node.children.isEmpty || shouldProgressiveSample params node.data then
    none
  else
    let scores := computePUCTScores params node
    -- I could not find a convenient way in Std to compute argmax of an array
    Id.run do
      let mut bestIdx := none
      let mut bestScore := -Float.inf
      for ((score, _), i) in scores.zipIdx do
        if score > bestScore then
          bestIdx := some i
          bestScore := score
      return bestIdx

def updateEdge (e : EdgeData) (value : Float) : EdgeData :=
  {
    e with
      numVisit := e.numVisit + 1
      value := e.value + value
  }

def backpropValueTowardsMin (node : NodeType) : Float :=
  Id.run do
    let mut value := 1.0
    for (_, child) in node.children do
      if !child.isSolved && child.numVisit > 0 then
        value := min value child.value
    return value

def backupValueForParent (node : NodeType) (value : Float) : Float :=
  match node.data.toPlay with
  | .orNode => value
  | .andNode => backpropValueTowardsMin node

def updateNode (node : NodeType) (value : Float) : NodeData :=
  {
    node.data with
      isSolved := nodeSolved node
      numVisit := node.data.numVisit + 1
      valueSum := node.data.valueSum + value
  }

def currentGoalType (node : NodeData) : TacticM String := do
  node.state.restore
  match ← getUnsolvedGoals with
  | [] => return "no goals"
  | goal :: _ =>
      goal.withContext do
        return toString (← Meta.ppExpr (← goal.getTypeCleanup))

def reportProgress? (progress? : Option ProgressReporter) (step maxNodes maxSteps : Nat)
    (goalType : String) (done solved : Bool) (status : String) : SearchM Unit := do
  match progress? with
  | none => return ()
  | some progress =>
      let nodes ← get
      liftM <| progress {
        visitedNodes := nodes.size
        maxNodes
        step
        maxSteps
        goalType
        done
        solved
        status
      }

unsafe def reapMCTSStep (ctx : ProofCheckContext) (evalPolicyValue : PolicyValueEval)
    (params : SearchHyperparameters) (ancestorKeys : Std.HashSet StateKey)
    (nodeIdx : Nat) (progress? : Option ProgressReporter := none)
    (step := 0) (maxNodes := MCTS.defaultMaxNodes) (maxSteps := MCTS.defaultMaxSteps)
    (observer? : Option MCTSObserver := none) : SearchM Float := do
  let x ← getNode! nodeIdx
  let node ← resolve x
  let selected := selectChild params node
  observe? observer? do
    return json%{
      kind: "selection", step: $step, node_index: $nodeIdx,
      child_position: $selected,
      child_index: $(selected.bind fun k => x.children[k]?.map Prod.snd)
    }
  match selected with
  | none =>
      let goalType ← currentGoalType node.data
      let value ← visitNode ctx evalPolicyValue ancestorKeys nodeIdx node observer? step
      reportProgress? progress? step maxNodes maxSteps goalType false false "running"
      return value
  | some childPos =>
      let (_, childIdx) ← getChild! x childPos
      let childRef ← getNode! childIdx
      let childValue ←
        reapMCTSStep ctx evalPolicyValue params (ancestorKeys.insert childRef.data.key) childIdx
          progress? step maxNodes maxSteps observer?
      let x ← getNode! nodeIdx
      let (edge, childIdx) ← getChild! x childPos
      let value := childValue - edgeStepCost edge
      let edge' := updateEdge edge value
      setAtT nodeIdx { x with children := x.children.set! childPos (edge', childIdx) }
      let node ← resolve (← getNode! nodeIdx)
      let data' := updateNode node value
      let x ← getNode! nodeIdx
      setAtT nodeIdx { x with data := data' }
      let node ← resolve (← getNode! nodeIdx)
      let backedUp := backupValueForParent node value
      observe? observer? do
        return json%{
          kind: "backup", step: $step, node_index: $nodeIdx,
          child_position: $childPos, child_index: $childIdx,
          child_value: $childValue, step_cost: $(edgeStepCost edge),
          backed_up_value: $backedUp, edge: $edge',
          node_value_sum: $(node.data.valueSum), node_visits: $(node.data.numVisit),
          node_kind: $(node.data.toPlay)
        }
      return backedUp

unsafe def monteCarloTreeSearch (ctx : ProofCheckContext) (evalPolicyValue : PolicyValueEval)
    (params : SearchHyperparameters) (start : NodeData)
    (maxNodes := MCTS.defaultMaxNodes) (maxSteps := MCTS.defaultMaxSteps)
    (progress? : Option ProgressReporter := none)
    (observer? : Option MCTSObserver := none) :
    TacticM (Option Nat × Array (Node NodeData (EdgeData × Nat))) :=
  StateT.run (s := #[ { data := start } ]) do
    let mut step := 0
    while (← get).size <= maxNodes && step < maxSteps do
      discard <| reapMCTSStep ctx evalPolicyValue params {start.key} 0 progress? step maxNodes maxSteps observer?
      reportCheckpoint? observer? params step
      let root ← getNode! 0
      if root.data.isSolved then
        reportProgress? progress? (step + 1) maxNodes maxSteps "no goals" true true "solved"
        return some 0
      step := step + 1
    reportProgress? progress? step maxNodes maxSteps "search exhausted" true false "exhausted"
    return none

def trimScript (script : String) : String :=
  script.trimAscii.toString

def appendScript (head tail : String) : String :=
  let head := trimScript head
  let tail := trimScript tail
  if head.isEmpty then
    tail
  else if tail.isEmpty then
    head
  else
    head ++ "\n" ++ tail

def renderBullet (script : String) : String :=
  let script := trimScript script
  let script := if script.isEmpty then "skip" else script
  match script.splitOn "\n" with
  | [] => "· skip"
  | first :: rest =>
      String.intercalate "\n" (("· " ++ first) :: rest.map fun line => "  " ++ line)

def indentScript (script : String) : String :=
  String.intercalate "\n" <| (trimScript script).splitOn "\n" |>.map fun line => "  " ++ line

def wrapProofScriptAsTactic (script : String) : String :=
  "exact by\n" ++ indentScript script

def childIsSolved (nodes : Array (Node NodeData (EdgeData × Nat))) (childIdx : Nat) : Bool :=
  (nodes[childIdx]?.map fun child => child.data.isSolved).getD false

def solvedOrChild? (nodes : Array (Node NodeData (EdgeData × Nat)))
    (node : Node NodeData (EdgeData × Nat)) : Option (EdgeData × Nat) :=
  node.children.find? fun (edge, childIdx) =>
    !edge.isFocus && childIsSolved nodes childIdx

def focusChildren
    (node : Node NodeData (EdgeData × Nat)) : Array (EdgeData × Nat) :=
  node.children.filter (fun (edge, _) => edge.isFocus)
  |>.qsort fun a b => a.1.focusIndex < b.1.focusIndex

def solvedFocusChildren (nodes : Array (Node NodeData (EdgeData × Nat)))
    (node : Node NodeData (EdgeData × Nat)) : Array (EdgeData × Nat) :=
  focusChildren node |>.filter fun (_, childIdx) => childIsSolved nodes childIdx

partial def proofScriptForSolvedNode
    (nodes : Array (Node NodeData (EdgeData × Nat))) (nodeIdx : Nat) : Except String String := do
  let some node := nodes[nodeIdx]? | throw s!"MCTS proof script node index out of bounds: {nodeIdx}"
  match node.data.toPlay with
  | .orNode =>
      match solvedOrChild? nodes node with
      | some (edge, childIdx) =>
          return appendScript edge.tacticStr (← proofScriptForSolvedNode nodes childIdx)
      | none =>
          if node.data.isSolved then
            return ""
          else
            throw s!"MCTS proof script could not find a solved OR child at node {nodeIdx}"
  | .andNode =>
      let focusChildren := solvedFocusChildren nodes node
      if focusChildren.isEmpty then
        if node.data.isSolved then
          return ""
        else
          throw s!"MCTS proof script could not find solved focus children at node {nodeIdx}"
      let mut bullets := #[]
      for (_, childIdx) in focusChildren do
        bullets := bullets.push (renderBullet (← proofScriptForSolvedNode nodes childIdx))
      return String.intercalate "\n" bullets.toList

partial def replaySolvedNode (ctx : ProofCheckContext) (heartbeats : Nat)
    (nodes : Array (Node NodeData (EdgeData × Nat))) (nodeIdx : Nat) : TacticM Unit := do
  let some node := nodes[nodeIdx]? | throwError "MCTS proof replay node index out of bounds: {nodeIdx}"
  match node.data.toPlay with
  | .orNode =>
      if (← getUnsolvedGoals).isEmpty then
        return ()
      let some (edge, childIdx) := solvedOrChild? nodes node
        | throwError "MCTS proof replay could not find a solved OR child"
      match ← evalTacticStrNoFinalCheck ctx edge.tacticStr heartbeats with
      | .ok _ => replaySolvedNode ctx heartbeats nodes childIdx
      | .error err => throwError "MCTS proof replay failed on tactic {edge.tacticStr}: {(toJson err).compress}"
  | .andNode =>
      let goals := (← getUnsolvedGoals).toArray
      for (edge, childIdx) in focusChildren node do
        unless childIsSolved nodes childIdx do
          throwError "MCTS proof replay encountered an unsolved AND child"
        let some goal := goals[edge.focusIndex]? | throwError "MCTS proof replay focus index out of bounds: {edge.focusIndex}"
        if !(← goal.isAssigned) then
          setGoals [goal]
          replaySolvedNode ctx heartbeats nodes childIdx
      setGoals goals.toList
      pruneSolvedGoals

end MCTS

open MCTS in
structure MCTSResult where
  ctx : ProofCheckContext
  solution? : Option Nat
  nodes : Array (Node MCTS.NodeData (MCTS.EdgeData × Nat))
  info : Json

open MCTS in
def runMCTS (evalPolicyValue : PolicyValueEval)
    (maxNodes := MCTS.defaultMaxNodes)
    (maxSteps := MCTS.defaultMaxSteps)
    (progress? : Option ProgressReporter := none)
    (observer? : Option MCTSObserver := none) : TacticM MCTSResult := unsafe do
  let opts ← getOptions
  let path := reap.wall_clock_log_path.get opts
  if !path.isEmpty then
    openLogFile <| .mk path
  let ctx ← mkProofCheckContext
  let params := SearchHyperparameters.fromOptions opts
  let (k, nodes) ←
    monteCarloTreeSearch ctx evalPolicyValue params (← NodeData.fromState) maxNodes maxSteps progress? observer?

  let ppNodes ← nodes.mapM (ppNode params nodes)
  let info := json%{
    solution : $k,
    nodes : $ppNodes
  }
  writeRawTree (reap.raw_tree_path.get opts) info
  return {
    ctx := ctx
    solution? := k
    nodes := nodes
    info := info
  }

def checkProofScript (ctx : ProofCheckContext) (script : String) : TacticM (EvalResult Unit) :=
  withoutModifyingState do
    let heartbeats := reap.heartbeats.get (← getOptions)
    match ← evalTacticStrNoFinalCheck ctx (MCTS.wrapProofScriptAsTactic script) heartbeats with
    | .ok _ => checkProof ctx
    | .error err => return .error err

open MCTS in
def reapMCTS (evalPolicyValue : PolicyValueEval)
    (maxNodes := MCTS.defaultMaxNodes)
    (maxSteps := MCTS.defaultMaxSteps) : TacticM Unit := unsafe do
  let result ← runMCTS evalPolicyValue maxNodes maxSteps

  if result.solution?.isSome then
    let heartbeats := reap.heartbeats.get (← getOptions)
    let some root := result.nodes[0]? | throwError "MCTS result has no root node"
    root.data.state.restore
    replaySolvedNode result.ctx heartbeats result.nodes 0
    match ← checkProof result.ctx with
    | .ok _ => return ()
    | .error err => throwError "MCTS final proof check failed after replay: {(toJson err).compress}"

end Reap.TreeSearch
