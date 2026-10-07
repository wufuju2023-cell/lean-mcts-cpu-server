/-! lmc session preamble — injected by lean-mcts-cpu-server (`lmc.shells.build_shell`).

Defines the `lmcSessionLoop` tactic: an interactive JSON-Lines session over stdio,
running inside the target theorem's tactic block. State handles are
`Tactic.SavedState` snapshots (the same mechanism as Reap's in-Lean MCTS nodes).

Protocol (one JSON object per line on stdin; responses on stdout, prefix `@@LMC@@ `):
  {"id": n, "op": "ping"}
  {"id": n, "op": "goals",  "state": h}
  {"id": n, "op": "apply",  "state": h, "tactic": "..."}
  {"id": n, "op": "focus",  "state": h, "index": i}
  {"id": n, "op": "verify", "state": h, "script": ["...", ...]}
  {"id": n, "op": "close"}

On close (or EOF): if `verify` succeeded, restore the verified state so the shell
file elaborates as a real proof; otherwise restore the root state and admit all
remaining goals (the file still compiles, with a `sorry` warning).
-/

open Lean Meta Elab Tactic

set_option Elab.async false
set_option maxHeartbeats 0

namespace LmcServer

/-- 获取本进程的真实 stdin。
在 check 模式下，elaborator 线程的 `IO.getStdin` 指向空流；
re-open `/proc/self/fd/0` 可绕过（Linux）。 -/
private def openRealStdin : IO IO.FS.Stream := do
  try
    let h ← IO.FS.Handle.mk "/proc/self/fd/0" .read
    return IO.FS.Stream.ofHandle h
  catch _ =>
    IO.getStdin

private def marker : String := "@@LMC@@ "

/-- 会话输出流：优先 `LMC_OUTPUT_FIFO`（check 模式下 task 线程的 stdout 被缓冲，
FIFO 文件句柄是实时的）；否则退回 stdout。 -/
private def openOutput : IO IO.FS.Stream := do
  match ← IO.getEnv "LMC_OUTPUT_FIFO" with
  | some path =>
    let h ← IO.FS.Handle.mk path .write
    return IO.FS.Stream.ofHandle h
  | none => IO.getStdout

private def emit (out : IO.FS.Stream) (j : Json) : IO Unit := do
  out.putStr (marker ++ j.compress ++ "\n")
  out.flush

private def okMsg (out : IO.FS.Stream) (id : Nat) (fields : List (String × Json)) : IO Unit :=
  emit out (Json.mkObj ([("id", toJson id), ("ok", toJson true)] ++ fields))

private def errMsg (out : IO.FS.Stream) (id : Nat) (kind : String) (message : String)
    (fields : List (String × Json) := []) : IO Unit :=
  emit out (Json.mkObj ([("id", toJson id), ("ok", toJson false),
                     ("kind", toJson kind), ("error", toJson message)] ++ fields))

private def ppGoals (goals : List MVarId) : MetaM (List String) :=
  goals.mapM fun g => do
    return toString (← Meta.ppGoal g)

private def heartbeatBudget : TacticM Nat :=
  return reap.heartbeats.get (← getOptions)

partial def runLoop : TacticM Unit := do
  let out ← openOutput
  let initial : Tactic.SavedState ← Tactic.saveState
  let ctx : Reap.TreeSearch.ProofCheckContext ← Reap.TreeSearch.mkProofCheckContext
  let mut states : Array Tactic.SavedState := #[initial]
  let mut solvedState : Option Tactic.SavedState := none
  let stdin ← openRealStdin
  let mut running := true
  while running do
    let line ← stdin.getLine
    if line.trimAscii.toString.isEmpty then
      running := false
    else
      match Json.parse line with
      | .error e =>
        errMsg out 0 "json" s!"parse error: {e}"
      | .ok req =>
        let id : Nat := (req.getObjValAs? Nat "id").toOption.getD 0
        let op : String := (req.getObjValAs? String "op").toOption.getD ""
        match op with
        | "ping" =>
          okMsg out id [("kind", toJson "pong"), ("states", toJson states.size)]
        | "goals" =>
          let sid : Nat := (req.getObjValAs? Nat "state").toOption.getD 0
          match states[sid]? with
          | none => errMsg out id "state" s!"bad state handle {sid} (have {states.size})"
          | some st =>
            st.restore
            let gs ← getUnsolvedGoals
            let pps ← ppGoals gs
            okMsg out id [("kind", toJson "goals"), ("num_goals", toJson gs.length),
                      ("goals", toJson pps)]
        | "apply" =>
          let sid : Nat := (req.getObjValAs? Nat "state").toOption.getD 0
          let tactic : String := (req.getObjValAs? String "tactic").toOption.getD ""
          match states[sid]? with
          | none => errMsg out id "state" s!"bad state handle {sid} (have {states.size})"
          | some st =>
            st.restore
            let t0 ← IO.monoMsNow
            let hb ← heartbeatBudget
            let result ← Reap.TreeSearch.evalTacticStrNoFinalCheck ctx tactic hb
            let elapsed := (← IO.monoMsNow) - t0
            match result with
            | .error err =>
              st.restore
              errMsg out id "tactic" (toJson err).compress
                [("closed", toJson false), ("elapsed_ms", toJson elapsed)]
            | .ok _ =>
              let gs ← getUnsolvedGoals
              let pps ← ppGoals gs
              let key := (toJson pps).compress
              let st' ← Tactic.saveState
              let newH := states.size
              states := states.push st'
              okMsg out id [("kind", toJson "apply_result"), ("state", toJson newH),
                        ("num_goals", toJson gs.length),
                        ("closed", toJson gs.isEmpty),
                        ("goals", toJson pps), ("state_key", toJson key),
                        ("elapsed_ms", toJson elapsed)]
        | "focus" =>
          let sid : Nat := (req.getObjValAs? Nat "state").toOption.getD 0
          let i : Nat := (req.getObjValAs? Nat "index").toOption.getD 0
          match states[sid]? with
          | none => errMsg out id "state" s!"bad state handle {sid} (have {states.size})"
          | some st =>
            st.restore
            let gs ← getUnsolvedGoals
            match gs[i]? with
            | none => errMsg out id "focus" s!"focus index {i} out of range ({gs.length} goals)"
            | some g =>
              setGoals [g]
              let pps ← ppGoals [g]
              let key := (toJson pps).compress
              let st' ← Tactic.saveState
              let newH := states.size
              states := states.push st'
              okMsg out id [("kind", toJson "focus_result"), ("state", toJson newH),
                        ("num_goals", toJson 1), ("goals", toJson pps),
                        ("state_key", toJson key)]
        | "verify" =>
          let sid : Nat := (req.getObjValAs? Nat "state").toOption.getD 0
          let script : List String :=
            (req.getObjValAs? (List String) "script").toOption.getD []
          match states[sid]? with
          | none => errMsg out id "state" s!"bad state handle {sid} (have {states.size})"
          | some st =>
            st.restore
            let hb ← heartbeatBudget
            let mut ok := true
            let mut failMsg := ""
            let mut executed := 0
            for t in script do
              if ok then
                executed := executed + 1
                let res ← Reap.TreeSearch.evalTacticStr ctx t hb
                match res with
                | .ok _ => pure ()
                | .error err =>
                  ok := false
                  failMsg := (toJson err).compress
            if ok then
              let gs ← getUnsolvedGoals
              if gs.isEmpty then
                solvedState := some (← Tactic.saveState)
                okMsg out id [("kind", toJson "verify_result"), ("verified", toJson true),
                          ("steps", toJson executed)]
              else
                st.restore
                errMsg out id "verify" "script did not close all goals"
                  [("verified", toJson false), ("attempted", toJson executed)]
            else
              st.restore
              errMsg out id "verify" failMsg
                [("verified", toJson false), ("attempted", toJson executed)]
        | "close" =>
          okMsg out id [("kind", toJson "closing")]
          running := false
        | _ =>
          errMsg out id "op" s!"unknown op {op}"
  match solvedState with
  | some st => st.restore
  | none =>
    match states[0]? with
    | some st =>
      st.restore
      let gs ← getUnsolvedGoals
      for g in gs do
        admitGoal g
    | none => pure ()

end LmcServer

elab "lmcSessionLoop" : tactic => LmcServer.runLoop
