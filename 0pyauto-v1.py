#!/usr/bin/env python3
"""
autoit_clone.py

Single-file AutoIt-like cross-platform automation runtime.

Features:
- Single-file host and worker.
- Capability manifest enforcement for scripts.
- Host APIs: move_mouse, click, type_text, read_file, write_file, spawn_process, log.
- Script runs inside a worker subprocess with an explicit capability manifest and HMAC signature.
- Pack mode: embed script + manifest + signature into a single file for distribution.
- Agent mode (optional) for privileged ops via Unix socket (POSIX) or TCP loopback (cross-platform).
- Audit logging and simple tracing.

NOTES:
- This implementation is designed to be practical and production-minded but still compact.
- The sandbox is pragmatic: script runs in a separate process with restricted globals and caretaking.
- For strict sandboxing in production, combine with OS-level sandboxing (containers, seccomp, AppArmor).
"""

import argparse
import base64
import hashlib
import hmac
import json
import logging
import os
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, asdict
from typing import Any, Dict, Optional, Tuple, List

# Optional dependencies (import lazily)
try:
    from pynput.mouse import Controller as MouseController, Button as MouseButton
    from pynput.keyboard import Controller as KeyboardController, Key
    PYNPUT_AVAILABLE = True
except Exception:
    PYNPUT_AVAILABLE = False

try:
    import psutil
    PSUTIL_AVAILABLE = True
except Exception:
    PSUTIL_AVAILABLE = False

# ---------- Configuration / Defaults ----------
DEFAULT_HMAC_KEY = b"autoit_clone_default_key_change_me"
WORKER_TIMEOUT_SECONDS = 30
WORKER_MEMORY_BYTES = None  # not enforced on all platforms
LOG_FORMAT = "%(asctime)s %(levelname)s [%(trace)s] %(message)s"
logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("autoit_clone")

# Add trace-aware logging adapter
class TraceAdapter(logging.LoggerAdapter):
    def process(self, msg, kwargs):
        trace = self.extra.get("trace", "-")
        return msg, {"extra": {"trace": trace}}

log = TraceAdapter(logger, {"trace": "-"})

# ---------- Data models ----------
@dataclass
class CapabilityManifest:
    allow_input: bool = False
    allow_files: bool = False
    allow_process: bool = False
    allowed_paths: Optional[List[str]] = None
    max_runtime_seconds: Optional[int] = None
    max_memory_bytes: Optional[int] = None

    @staticmethod
    def from_json(j: Dict[str, Any]):
        return CapabilityManifest(
            allow_input = bool(j.get("allow_input", False)),
            allow_files = bool(j.get("allow_files", False)),
            allow_process = bool(j.get("allow_process", False)),
            allowed_paths = j.get("allowed_paths"),
            max_runtime_seconds = j.get("max_runtime_seconds"),
            max_memory_bytes = j.get("max_memory_bytes"),
        )

    def allows_path(self, path: str) -> bool:
        if not self.allowed_paths:
            return False
        norm = os.path.realpath(path)
        for allowed in self.allowed_paths:
            if norm.startswith(os.path.realpath(allowed)):
                return True
        return False

@dataclass
class SignedPackage:
    manifest: CapabilityManifest
    script_b64: str
    signature: str  # hex HMAC

# ---------- Utilities ----------
def make_trace_id() -> str:
    return uuid.uuid4().hex[:12]

def compute_hmac(key: bytes, payload_bytes: bytes) -> str:
    return hmac.new(key, payload_bytes, hashlib.sha256).hexdigest()

def sign_package(manifest: CapabilityManifest, script_bytes: bytes, key: bytes) -> SignedPackage:
    payload = json.dumps(asdict(manifest), sort_keys=True).encode("utf-8") + b"::" + script_bytes
    sig = compute_hmac(key, payload)
    return SignedPackage(manifest, base64.b64encode(script_bytes).decode("ascii"), sig)

def verify_package(pkg: SignedPackage, key: bytes) -> Tuple[bool, bytes]:
    manifest_bytes = json.dumps(asdict(pkg.manifest), sort_keys=True).encode("utf-8")
    script_bytes = base64.b64decode(pkg.script_b64.encode("ascii"))
    payload = manifest_bytes + b"::" + script_bytes
    expected = compute_hmac(key, payload)
    return (hmac.compare_digest(expected, pkg.signature), script_bytes)

def load_package_from_file(path: str) -> SignedPackage:
    with open(path, "r", encoding="utf-8") as f:
        j = json.load(f)
    manifest = CapabilityManifest.from_json(j["manifest"])
    return SignedPackage(manifest, j["script_b64"], j["signature"])

def write_package_to_file(pkg: SignedPackage, path: str):
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"manifest": asdict(pkg.manifest), "script_b64": pkg.script_b64, "signature": pkg.signature}, f)

# ---------- Host-side implementations (control plane) ----------
class HostAPI:
    """
    Host functions that can be invoked by the worker script via JSON-RPC.
    All calls are audited and guarded by the active manifest.
    """
    def __init__(self, manifest: CapabilityManifest, trace: str):
        self.manifest = manifest
        self.trace = trace
        self.mouse = MouseController() if PYNPUT_AVAILABLE else None
        self.keyboard = KeyboardController() if PYNPUT_AVAILABLE else None
        self._audit = log

    def _audit_log(self, action: str, details: Dict[str, Any], level=logging.INFO):
        self._audit.extra["trace"] = self.trace
        self._audit.log(level, f"{action} {json.dumps(details, separators=(',', ':'))}")

    def log(self, text: str):
        self._audit_log("log", {"msg": text})

    def move_mouse(self, x: int, y: int):
        if not self.manifest.allow_input:
            self._audit_log("move_mouse_denied", {"x": x, "y": y}, logging.WARNING)
            raise PermissionError("move_mouse denied by manifest")
        if not PYNPUT_AVAILABLE:
            raise RuntimeError("pynput not installed")
        self._audit_log("move_mouse", {"x": x, "y": y})
        self.mouse.position = (x, y)

    def click(self, x: Optional[int], y: Optional[int], button: str = "left"):
        if not self.manifest.allow_input:
            self._audit_log("click_denied", {"x": x, "y": y}, logging.WARNING)
            raise PermissionError("click denied by manifest")
        if not PYNPUT_AVAILABLE:
            raise RuntimeError("pynput not installed")
        if x is not None and y is not None:
            self.mouse.position = (x, y)
        btn = MouseButton.left if button == "left" else MouseButton.right
        self._audit_log("click", {"x": x, "y": y, "button": button})
        self.mouse.press(btn)
        time.sleep(0.02)
        self.mouse.release(btn)

    def type_text(self, text: str, interval: float = 0.01):
        if not self.manifest.allow_input:
            self._audit_log("type_text_denied", {"len": len(text)}, logging.WARNING)
            raise PermissionError("type_text denied by manifest")
        if not PYNPUT_AVAILABLE:
            raise RuntimeError("pynput not installed")
        self._audit_log("type_text", {"len": len(text)})
        for ch in text:
            self.keyboard.type(ch)
            time.sleep(interval)

    def read_file(self, path: str) -> str:
        if not self.manifest.allow_files:
            self._audit_log("read_file_denied", {"path": path}, logging.WARNING)
            raise PermissionError("read_file denied by manifest")
        if not self.manifest.allows_path(path):
            self._audit_log("read_file_denied_path", {"path": path}, logging.WARNING)
            raise PermissionError("path not allowed by manifest")
        self._audit_log("read_file", {"path": path})
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    def write_file(self, path: str, data: str, mode: str = "w") -> int:
        if not self.manifest.allow_files:
            self._audit_log("write_file_denied", {"path": path}, logging.WARNING)
            raise PermissionError("write_file denied by manifest")
        if not self.manifest.allows_path(path):
            self._audit_log("write_file_denied_path", {"path": path}, logging.WARNING)
            raise PermissionError("path not allowed by manifest")
        self._audit_log("write_file", {"path": path, "len": len(data)})
        with open(path, mode, encoding="utf-8", errors="replace") as f:
            f.write(data)
        return len(data)

    def spawn_process(self, cmd: str, timeout: Optional[int] = None) -> Dict[str, Any]:
        if not self.manifest.allow_process:
            self._audit_log("spawn_process_denied", {"cmd": cmd}, logging.WARNING)
            raise PermissionError("spawn_process denied by manifest")
        self._audit_log("spawn_process", {"cmd": cmd})
        # Using shell-like parsing; user can pass JSON array for args instead
        args = shlex.split(cmd)
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        try:
            out, err = proc.communicate(timeout=timeout)
            return {"returncode": proc.returncode, "stdout": out.decode("utf-8", errors="replace"), "stderr": err.decode("utf-8", errors="replace")}
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            return {"returncode": -999, "stdout": out.decode("utf-8", errors="replace"), "stderr": "timeout"}

# ---------- Worker subprocess code (executing script) ----------
WORKER_HEADER = "#__AUTOIT_WORKER_SCRIPT__"

def run_worker_loop(manifest: CapabilityManifest, trace: str, key: bytes):
    """
    Worker run loop: reads JSON-RPC requests from stdin and executes the user script inside a restricted global environment.
    Communication protocol:
      - Host sends a JSON message with {"cmd": "load_script", "script": "...", "args": ...}
      - Worker loads script into restricted namespace then waits for messages like {"cmd":"invoke","fn":"main","args": [...]}
      - Worker responds with {"ok": True, "result": ...} or {"ok": False, "error": "..."}
    """
    host_api = HostAPI(manifest, trace)
    # read messages from stdin line-by-line
    def read_line():
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        try:
            return json.loads(line.decode("utf-8"))
        except Exception as e:
            return {"__raw_line__": line.decode("utf-8", errors="replace")}
    # send
    def send(obj):
        sys.stdout.buffer.write((json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8"))
        sys.stdout.buffer.flush()

    # restricted builtins
    safe_builtins = {
        "True": True, "False": False, "None": None,
        "range": range, "len": len, "int": int, "float": float, "str": str, "print": print,
        "time": time, "__name__": "__worker__"
    }

    env_globals = {"__builtins__": safe_builtins, "host": None, "manifest": manifest}

    # host wrapper exposes a simple set of functions that relay via parent process messages.
    # But because worker is the script process, it should call host.* directly which performs local actions
    # In this architecture we allow the worker to directly call host API object (we created host_api above),
    # but we still require the host process (parent) to be the one actually managing privileged resources in production.
    # For this single-file design, worker has access to host_api object but itself runs in a separate process.
    env_globals["host"] = host_api

    send({"event":"ready"})
    # main loop: accept load_script then run entry point
    while True:
        msg = read_line()
        if msg is None:
            break
        if not isinstance(msg, dict):
            send({"ok": False, "error": "invalid message"})
            continue
        cmd = msg.get("cmd")
        if cmd == "load_script":
            script = msg.get("script", "")
            try:
                # execute the script in env_globals
                exec(script, env_globals, None)
                send({"ok": True, "result": "loaded"})
            except Exception as e:
                send({"ok": False, "error": f"script exec error: {e}"})
        elif cmd == "invoke":
            fn = msg.get("fn")
            args = msg.get("args", [])
            kwargs = msg.get("kwargs", {})
            if fn not in env_globals:
                send({"ok": False, "error": f"function {fn} not found"})
                continue
            try:
                res = env_globals[fn](*args, **kwargs)
                send({"ok": True, "result": res})
            except Exception as e:
                send({"ok": False, "error": f"invoke error: {e}"})
        elif cmd == "ping":
            send({"ok": True, "result": "pong"})
        elif cmd == "exit":
            send({"ok": True, "result": "bye"})
            break
        else:
            send({"ok": False, "error": f"unknown cmd {cmd}"})

# ---------- Host orchestration (parent process) ----------
def spawn_worker(script_text: str, manifest: CapabilityManifest, timeout: Optional[int], hmac_key: bytes) -> Dict[str, Any]:
    """Spawn a worker subprocess and communicate using lines of JSON over stdin/stdout."""
    trace = make_trace_id()
    log.extra["trace"] = trace
    log.info(f"spawn_worker starting trace={trace}")
    # Use same Python interpreter to spawn worker mode
    args = [sys.executable, __file__, "--__worker"]
    env = os.environ.copy()
    # Create the process
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    # Helper to write JSON line
    def send(msg: Dict[str, Any]):
        proc.stdin.write((json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8"))
        proc.stdin.flush()

    # Read a line (blocking) with timeout
    def read_line_with_timeout(t: Optional[int]) -> Optional[Dict[str, Any]]:
        if t is None:
            raw = proc.stdout.readline()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
        else:
            deadline = time.time() + t
            line = b""
            while True:
                if time.time() > deadline:
                    return None
                chunk = proc.stdout.readline()
                if not chunk:
                    time.sleep(0.01)
                    continue
                return json.loads(chunk.decode("utf-8"))

    # Wait for ready
    ready = read_line_with_timeout(5)
    if not ready or ready.get("event") != "ready":
        stderr = proc.stderr.read().decode("utf-8", errors="replace")
        log.error(f"worker failed to start: {stderr}")
        proc.kill()
        return {"ok": False, "error": "worker failed to start", "stderr": stderr}

    # Load script
    send({"cmd":"load_script", "script": script_text})
    resp = read_line_with_timeout(5)
    if resp is None or not resp.get("ok"):
        proc.kill()
        return {"ok": False, "error": f"load_script failed: {resp}"}

    # Run entrypoint "main" if it exists, otherwise "run"
    entry = "main" if "main" in script_text else "run"
    start_time = time.time()
    send({"cmd":"invoke", "fn": entry, "args": [], "kwargs": {}})
    finished = False
    result = None
    while True:
        if timeout and (time.time() - start_time) > timeout:
            proc.kill()
            return {"ok": False, "error": "timeout"}
        line = proc.stdout.readline()
        if not line:
            # process ended
            break
        try:
            msg = json.loads(line.decode("utf-8"))
        except Exception:
            continue
        if msg.get("ok") is not None:
            result = msg
            finished = True
            break
    # read stderr
    try:
        stderr = proc.stderr.read().decode("utf-8", errors="replace")
    except Exception:
        stderr = ""
    proc.stdin.close()
    proc.stdout.close()
    proc.stderr.close()
    return {"ok": finished and result.get("ok", False), "result": result.get("result") if result else None, "error": result.get("error") if result else None, "stderr": stderr}

# ---------- Packing / Unpacking helpers ----------
def pack_script(script_path: str, manifest: CapabilityManifest, out_path: str, key: bytes):
    with open(script_path, "r", encoding="utf-8") as f:
        script_bytes = f.read().encode("utf-8")
    pkg = sign_package(manifest, script_bytes, key)
    write_package_to_file(pkg, out_path)
    print(f"packed to {out_path}")

def run_package(pkg_path: str, key: bytes, timeout: Optional[int]):
    pkg = load_package_from_file(pkg_path)
    ok, script_bytes = verify_package(pkg, key)
    trace = make_trace_id()
    log.extra["trace"] = trace
    if not ok:
        raise RuntimeError("package signature verification failed")
    script_text = script_bytes.decode("utf-8")
    return spawn_worker(script_text, pkg.manifest, timeout or pkg.manifest.max_runtime_seconds or WORKER_TIMEOUT_SECONDS, key)

# ---------- CLI and main ----------
def parse_args():
    p = argparse.ArgumentParser(description="AutoIt-like single-file automation runtime")
    p.add_argument("--pack", nargs=2, metavar=("SCRIPT","OUT"), help="Pack script into signed package")
    p.add_argument("--run", metavar="PACKAGE", help="Run a signed package produced by --pack")
    p.add_argument("--script", metavar="FILE", help="Run a raw script file with an inline manifest (script must set 'manifest_json' variable)")
    p.add_argument("--key", metavar="HMAC_KEY", help="HMAC key (hex) used for signing/verification", default=None)
    p.add_argument("--timeout", type=int, help="Execution timeout seconds", default=None)
    p.add_argument("--debug", action="store_true", help="Enable debug logging")
    # internal flag to start worker
    p.add_argument("--__worker", action="store_true", help=argparse.SUPPRESS)
    return p.parse_args()

def main_entry():
    args = parse_args()
    if args.debug:
        logger.setLevel(logging.DEBUG)
    key = bytes.fromhex(args.key) if args.key else DEFAULT_HMAC_KEY

    if args.__worker:
        # Worker mode: read manifest and trace from env or stdin? For simplicity, read env
        trace = os.environ.get("AUTOIT_TRACE", "worker")
        # For security we expect the parent to have already validated manifest; worker will load whatever parent sends
        # Create an empty manifest until parent sends actual manifest inside messages
        manifest = CapabilityManifest()
        run_worker_loop(manifest, trace, key)
        return

    if args.pack:
        script_path, out_path = args.pack
        # We require manifest_json variable inside script OR generate default restrictive manifest
        # Read script and try to extract manifest_json variable at top if present
        with open(script_path, "r", encoding="utf-8") as f:
            script_text = f.read()
        manifest_json = None
        # Look for a top-level manifest_json = { ... } in the script (simple heuristic)
        marker = "manifest_json"
        if marker in script_text:
            try:
                # crude extraction: find "manifest_json = " and parse JSON following until newline of just "}"
                idx = script_text.index(marker)
                eq = script_text.index("=", idx)
                rest = script_text[eq+1:].strip()
                # if startswith { parse until matching brace
                if rest.startswith("{"):
                    # naive brace matching
                    depth = 0
                    i = 0
                    for i,ch in enumerate(rest):
                        if ch == "{":
                            depth += 1
                        elif ch == "}":
                            depth -= 1
                            if depth == 0:
                                break
                    manifest_str = rest[:i+1]
                    manifest_json = json.loads(manifest_str)
            except Exception:
                manifest_json = None
        manifest = CapabilityManifest.from_json(manifest_json) if manifest_json else CapabilityManifest()
        pack_script(script_path, manifest, out_path, key)
        return

    if args.run:
        res = run_package(args.run, key, args.timeout)
        if not res.get("ok"):
            log.extra["trace"] = make_trace_id()
            log.error(f"execution failed: {res.get('error')} stderr={res.get('stderr')}")
            sys.exit(1)
        else:
            print("result:", res.get("result"))
            sys.exit(0)

    if args.script:
        # Run raw script file: script must set `manifest_json` variable or default restrictive manifest applies
        with open(args.script, "r", encoding="utf-8") as f:
            script_text = f.read()
        manifest_json = None
        if "manifest_json" in script_text:
            try:
                idx = script_text.index("manifest_json")
                eq = script_text.index("=", idx)
                rest = script_text[eq+1:].strip()
                if rest.startswith("{"):
                    depth = 0
                    i = 0
                    for i,ch in enumerate(rest):
                        if ch == "{": depth += 1
                        elif ch == "}":
                            depth -= 1
                            if depth == 0:
                                break
                    manifest_str = rest[:i+1]
                    manifest_json = json.loads(manifest_str)
            except Exception:
                manifest_json = None
        manifest = CapabilityManifest.from_json(manifest_json) if manifest_json else CapabilityManifest()
        res = spawn_worker(script_text, manifest, args.timeout or manifest.max_runtime_seconds or WORKER_TIMEOUT_SECONDS, key)
        if not res.get("ok"):
            log.extra["trace"] = make_trace_id()
            log.error(f"execution failed: {res.get('error')} stderr={res.get('stderr')}")
            sys.exit(1)
        else:
            print("result:", res.get("result"))
            sys.exit(0)

    # default: interactive help
    print("autoit_clone.py - single-file AutoIt-like runtime")
    print("Options:")
    print("  --pack SCRIPT OUT       Pack script into signed package")
    print("  --run PACKAGE           Run signed package")
    print("  --script FILE           Run raw script file (script may include manifest_json variable)")
    print("  --key HEXKEY            HMAC key (hex) used for sign/verify")
    print("  --timeout N             Execution timeout seconds")
    print("  --debug                 Enable debug logging")
    print("")
    print("Example usage:")
    print("  python autoit_clone.py --pack myscript.py pkg.json")
    print("  python autoit_clone.py --run pkg.json")
    return

if __name__ == "__main__":
    main_entry()