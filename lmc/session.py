"""Lean 会话客户端：以 `lake env lean shell.lean` 启动，走 JSON Lines stdio 协议。

协议响应带 `@@LMC@@ ` 前缀；请求-响应按 id 配对。
"""

from __future__ import annotations

import fcntl
import json
import os
import queue
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

MARKER = "@@LMC@@ "


class SessionError(RuntimeError):
    pass


class SessionTimeout(SessionError):
    pass


@dataclass
class ApplyResult:
    ok: bool
    closed: bool = False
    num_goals: int = 0
    state: int | None = None
    state_key: str = ""
    goals: list[str] = field(default_factory=list)
    elapsed_ms: float | None = None
    rtt_ms: float | None = None
    error: str = ""
    raw: dict = field(default_factory=dict)


class LeanSession:
    def __init__(
        self,
        shell: str | Path,
        *,
        cwd: str | Path,
        env: dict[str, str] | None = None,
        startup_timeout: float = 900.0,
        name: str = "session",
    ) -> None:
        self.name = name
        self.shell = str(shell)
        self.cwd = str(cwd)
        self._id = 0
        self._stdout_q: queue.Queue[str | None] = queue.Queue()
        self.stderr_lines: list[str] = []
        self.stdout_lines: list[str] = []
        env = dict(env or os.environ)
        # 输出通道：check 模式下 Lean task 线程的 stdout 被缓冲，改用 FIFO（实时）。
        from .paths import RUN_DIR
        fifo_dir = RUN_DIR / "fifos"
        fifo_dir.mkdir(parents=True, exist_ok=True)
        self.fifo_path = str(fifo_dir / f"{name}-{os.getpid()}-{int(time.time()*1000) % 100000}.fifo")
        try:
            os.unlink(self.fifo_path)
        except FileNotFoundError:
            pass
        os.mkfifo(self.fifo_path)
        self._fifo_rfd = os.open(self.fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        self._fifo_wfd = os.open(self.fifo_path, os.O_WRONLY | os.O_NONBLOCK)
        flags = fcntl.fcntl(self._fifo_rfd, fcntl.F_GETFL)
        fcntl.fcntl(self._fifo_rfd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
        env["LMC_OUTPUT_FIFO"] = self.fifo_path
        cmd = ["lake", "env", "lean", self.shell]
        self.proc = subprocess.Popen(
            cmd,
            cwd=self.cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._pump_fifo, daemon=True).start()
        threading.Thread(target=self._pump_stdout, daemon=True).start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()
        self.startup_s = self._wait_ready(startup_timeout)

    # ------------------------------------------------------------------ #
    # 内部 IO
    # ------------------------------------------------------------------ #
    def _pump_fifo(self) -> None:
        with os.fdopen(self._fifo_rfd, "r", encoding="utf-8") as fh:
            for line in fh:
                self._stdout_q.put(line.rstrip("\n"))

    def _pump_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            if line.strip():
                self.stdout_lines.append(line.rstrip("\n"))

    def _pump_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip("\n"))

    def _wait_ready(self, timeout: float) -> float:
        t0 = time.monotonic()
        resp = self.request("ping", timeout=timeout)
        if not resp.get("ok"):
            raise SessionError(f"{self.name}: ping failed: {resp}")
        return time.monotonic() - t0

    def request(self, op: str, timeout: float | None = None, **fields) -> dict:
        self._id += 1
        rid = self._id
        payload = {"id": rid, "op": op, **fields}
        try:
            assert self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError) as exc:
            raise SessionError(
                f"{self.name}: cannot write to process; stderr tail: {self.stderr_lines[-3:]}"
            ) from exc
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            remaining = None
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SessionTimeout(
                        f"{self.name}: timeout waiting for {op!r}; stderr tail: {self.stderr_lines[-3:]}"
                    )
            try:
                line = self._stdout_q.get(timeout=remaining)
            except queue.Empty:
                raise SessionTimeout(f"{self.name}: timeout waiting for {op!r}")
            if line is None:
                raise SessionError(
                    f"{self.name}: process exited (rc={self.proc.poll()}); "
                    f"stderr tail: {self.stderr_lines[-5:]}"
                )
            if not line.startswith(MARKER):
                # Lean 侧杂散输出（少见）；忽略但留痕
                if line.strip():
                    self.stderr_lines.append(f"[stdout-extra] {line}")
                continue
            try:
                resp = json.loads(line[len(MARKER):])
            except json.JSONDecodeError:
                continue
            if resp.get("id") == rid or resp.get("id") is None:
                return resp
            # 陈旧响应：跳过

    # ------------------------------------------------------------------ #
    # 便捷操作
    # ------------------------------------------------------------------ #
    def goals(self, state: int = 0, timeout: float | None = 240.0) -> dict:
        return self.request("goals", timeout=timeout, state=state)

    def apply(self, state: int, tactic: str, timeout: float | None = 300.0) -> ApplyResult:
        t0 = time.monotonic()
        resp = self.request("apply", timeout=timeout, state=state, tactic=tactic)
        rtt_ms = (time.monotonic() - t0) * 1000.0
        if not resp.get("ok"):
            return ApplyResult(ok=False, error=str(resp.get("message", resp)),
                               rtt_ms=rtt_ms, raw=resp)
        return ApplyResult(
            ok=True,
            closed=bool(resp.get("closed")),
            num_goals=int(resp.get("num_goals", 0)),
            state=int(resp["state"]) if "state" in resp else None,
            state_key=str(resp.get("state_key", "")),
            goals=[str(g) for g in resp.get("goals", [])],
            elapsed_ms=float(resp.get("elapsed_ms", 0.0)),
            rtt_ms=rtt_ms,
            raw=resp,
        )

    def focus(self, state: int, index: int, timeout: float | None = 120.0) -> ApplyResult:
        resp = self.request("focus", timeout=timeout, state=state, index=index)
        if not resp.get("ok"):
            return ApplyResult(ok=False, error=str(resp.get("message", resp)), raw=resp)
        return ApplyResult(
            ok=True,
            num_goals=1,
            state=int(resp["state"]) if "state" in resp else None,
            state_key=str(resp.get("state_key", "")),
            goals=[str(g) for g in resp.get("goals", [])],
            raw=resp,
        )

    def verify(self, state: int, script: list[str], timeout: float | None = 1200.0) -> dict:
        return self.request("verify", timeout=timeout, state=state, script=script)

    def close(self, timeout: float = 120.0) -> int | None:
        try:
            self.request("close", timeout=min(timeout, 30.0))
        except Exception:
            pass
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = self.proc.wait(timeout=10.0)
        self._cleanup_fifo()
        return rc

    def _cleanup_fifo(self) -> None:
        try:
            os.close(self._fifo_wfd)
        except OSError:
            pass
        try:
            os.unlink(self.fifo_path)
        except OSError:
            pass

    def kill(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()

    def rss_mb(self) -> float | None:
        try:
            with open(f"/proc/{self.proc.pid}/status", "r", encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("VmHWM:"):
                        return float(line.split()[1]) / 1024.0
        except OSError:
            pass
        return None
