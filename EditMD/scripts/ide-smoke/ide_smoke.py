#!/usr/bin/env python3
"""Integration smoke test for EditMD's Claude Code IDE channel (v36).

The IDE protocol is reverse-engineered, not a published contract: a CLI release
can change it under us. This script imitates what `claude` does on `/ide` —
find the lock file, upgrade a WebSocket with the auth header, run the MCP
handshake, call every tool — so a break shows up here rather than as "Claude
just stopped seeing my editor".

Standard library only (no `websockets` package): the handshake and framing are
small enough to do by hand.

    python3 ide_smoke.py              # auto-discover the lock file
    python3 ide_smoke.py --port 51234 # pick one explicitly
    python3 ide_smoke.py --open-diff  # also send openDiff (needs a human click)

`openDiff` blocks on a real user decision, so it is opt-in: the script proves
the request was *delivered* (the sheet appears) and prints whatever the user
chose. Everything else is asserted automatically.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
import socket
import struct
import sys
from pathlib import Path
from typing import Any

LOCK_DIR = Path.home() / ".claude" / "ide"
AUTH_HEADER = "x-claude-code-ide-authorization"
PROTOCOL_VERSION = "2025-03-26"

EXPECTED_TOOLS = {
    "getCurrentSelection", "getLatestSelection", "getOpenEditors",
    "getWorkspaceFolders", "openFile", "openDiff", "checkDocumentDirty",
    "saveDocument", "close_tab", "closeAllDiffTabs", "getDiagnostics",
    "executeCode",
}


class SmokeFailure(Exception):
    pass


# --------------------------------------------------------------------------
# Minimal WebSocket client (RFC 6455, text frames, client-masked)
# --------------------------------------------------------------------------

class WebSocket:
    def __init__(self, host: str, port: int, token: str, timeout: float = 15.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._buffer = b""
        self._handshake(host, port, token)

    def _handshake(self, host: str, port: int, token: str) -> None:
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"{AUTH_HEADER}: {token}\r\n"
            f"\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SmokeFailure("server closed the connection during the upgrade")
            response += chunk
        status = response.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise SmokeFailure(f"upgrade rejected: {status}")
        self._buffer = response.split(b"\r\n\r\n", 1)[1]

    def send(self, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode()
        header = bytearray([0x81])  # FIN + text opcode
        mask = secrets.token_bytes(4)
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        header += mask
        masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
        self.sock.sendall(bytes(header) + masked)

    def _read(self, count: int) -> bytes:
        while len(self._buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SmokeFailure("connection closed while reading a frame")
            self._buffer += chunk
        head, self._buffer = self._buffer[:count], self._buffer[count:]
        return head

    def recv(self) -> dict[str, Any]:
        """Returns the next text frame as parsed JSON, skipping control frames."""
        while True:
            first, second = self._read(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            masked = bool(second & 0x80)
            mask = self._read(4) if masked else b""
            payload = self._read(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise SmokeFailure("server sent a close frame")
            if opcode in (0x9, 0xA):  # ping / pong
                continue
            return json.loads(payload)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------
# JSON-RPC helpers
# --------------------------------------------------------------------------

class Client:
    def __init__(self, ws: WebSocket):
        self.ws = ws
        self._id = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        """Sends a request and returns its `result`, skipping notifications."""
        self._id += 1
        request_id = self._id
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.ws.send(message)
        while True:
            reply = self.ws.recv()
            if reply.get("id") != request_id:
                continue  # a notification (selection_changed) crossed our reply
            if "error" in reply:
                raise SmokeFailure(f"{method} → error {reply['error']}")
            return reply["result"]

    def tool(self, name: str, arguments: dict[str, Any] | None = None) -> Any:
        """Calls a tool and unwraps `content[0].text` (JSON string or status)."""
        result = self.call("tools/call", {"name": name, "arguments": arguments or {}})
        content = result.get("content") or []
        if not content:
            raise SmokeFailure(f"{name} returned no content array")
        text = content[0].get("text", "")
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text  # bare status: FILE_SAVED / TAB_CLOSED / …


# --------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------

def find_lock(port: int | None) -> tuple[int, dict[str, Any]]:
    if not LOCK_DIR.is_dir():
        raise SmokeFailure(f"{LOCK_DIR} does not exist — is EditMD running with the integration on?")

    candidates: list[tuple[int, dict[str, Any]]] = []
    for entry in sorted(LOCK_DIR.glob("*.lock")):
        try:
            data = json.loads(entry.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("ideName") != "EditMD":
            continue
        candidates.append((int(entry.stem), data))

    if port is not None:
        for found_port, data in candidates:
            if found_port == port:
                return found_port, data
        raise SmokeFailure(f"no EditMD lock file for port {port}")

    if not candidates:
        raise SmokeFailure("no EditMD lock file found in ~/.claude/ide")
    if len(candidates) > 1:
        ports = ", ".join(str(p) for p, _ in candidates)
        raise SmokeFailure(f"several EditMD instances ({ports}) — pass --port")
    return candidates[0]


def check_permissions(port: int) -> list[str]:
    problems = []
    lock = LOCK_DIR / f"{port}.lock"
    if (lock.stat().st_mode & 0o777) != 0o600:
        problems.append(f"{lock} is not 0600")
    if (LOCK_DIR.stat().st_mode & 0o777) != 0o700:
        problems.append(f"{LOCK_DIR} is not 0700")
    return problems


# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

PASSED = 0
FAILED: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    global PASSED
    if condition:
        PASSED += 1
        print(f"  ok    {label}")
    else:
        FAILED.append(label)
        print(f"  FAIL  {label}{(' — ' + detail) if detail else ''}")


def run(client: Client, lock: dict[str, Any], with_diff: bool) -> None:
    print("\n· handshake")
    result = client.call("initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "ide-smoke", "version": "1"},
    })
    check("initialize returns the pinned protocol version",
          result.get("protocolVersion") == PROTOCOL_VERSION, str(result))
    check("serverInfo names EditMD",
          (result.get("serverInfo") or {}).get("name") == "EditMD", str(result))
    check("capabilities advertise tools", "tools" in (result.get("capabilities") or {}))

    # The CLI sends this and expects silence; a reply here is a protocol error.
    client.ws.send({"jsonrpc": "2.0", "method": "initialized"})

    print("\n· tools/list")
    tools = client.call("tools/list").get("tools", [])
    names = {tool["name"] for tool in tools}
    check("exactly the 12 standard tools", names == EXPECTED_TOOLS,
          f"unexpected: {names ^ EXPECTED_TOOLS}")
    check("every tool has an inputSchema", all("inputSchema" in tool for tool in tools))

    print("\n· workspace / editors")
    folders = client.tool("getWorkspaceFolders")
    check("getWorkspaceFolders succeeds", folders.get("success") is True, str(folders))
    check("workspaceFolders match the lock file",
          [f["path"] for f in folders.get("folders", [])] == lock["workspaceFolders"],
          f"{folders.get('folders')} vs {lock['workspaceFolders']}")

    editors = client.tool("getOpenEditors")
    check("getOpenEditors returns a tabs array", isinstance(editors.get("tabs"), list))
    active = [tab for tab in editors.get("tabs", []) if tab.get("isActive")]
    check("at most one active tab", len(active) <= 1)

    print("\n· selection")
    selection = client.tool("getCurrentSelection")
    if selection.get("success"):
        sel = selection["selection"]
        check("selection carries a file path", bool(selection.get("filePath")))
        check("selection has line/character positions",
              "line" in sel["start"] and "character" in sel["end"], str(sel))
        print(f"        text: {selection['text'][:60]!r}")
    else:
        print("        (no active editor — open a file in EditMD to exercise this)")
    latest = client.tool("getLatestSelection")
    check("getLatestSelection answers", "success" in latest, str(latest))

    print("\n· document state")
    target = active[0]["uri"].removeprefix("file://") if active else None
    if target:
        dirty = client.tool("checkDocumentDirty", {"filePath": target})
        check("checkDocumentDirty reports the open file", dirty.get("success") is True, str(dirty))
        check("isDirty is a boolean", isinstance(dirty.get("isDirty"), bool))
    missing = client.tool("checkDocumentDirty", {"filePath": "/nonexistent/file.md"})
    check("checkDocumentDirty on a closed file is a soft failure",
          missing.get("success") is False, str(missing))

    print("\n· diagnostics (EditMD lint)")
    diagnostics = client.tool("getDiagnostics")
    check("getDiagnostics returns a list", isinstance(diagnostics, list), str(diagnostics)[:120])
    if diagnostics:
        entry = diagnostics[0]
        check("diagnostics entry has a uri", "uri" in entry)
        for item in entry.get("diagnostics", [])[:1]:
            check("diagnostic has message/severity/source",
                  {"message", "severity", "source"} <= set(item))
            check("diagnostic source is editmd-lint", item["source"] == "editmd-lint")
            print(f"        {item['severity']}: {item['message']}")

    print("\n· refusals and tabs")
    execute = client.tool("executeCode", {"code": "print(1)"})
    check("executeCode is a soft refusal", execute.get("success") is False, str(execute))
    closed = client.tool("closeAllDiffTabs")
    check("closeAllDiffTabs answers CLOSED_N_DIFF_TABS",
          isinstance(closed, str) and closed.startswith("CLOSED_"), str(closed))
    check("close_tab answers TAB_CLOSED",
          client.tool("close_tab", {"tab_name": "no-such-tab"}) == "TAB_CLOSED")

    if not with_diff:
        print("\n· openDiff skipped (pass --open-diff to exercise it)")
        return

    print("\n· openDiff — BLOCKING: accept or reject the sheet in EditMD")
    if not target:
        print("        no active file; open one in EditMD first")
        return
    original = Path(target).read_text()
    outcome = client.tool("openDiff", {
        "old_file_path": target,
        "new_file_path": target,
        "new_file_contents": original + "\n<!-- ide-smoke touched this -->\n",
        "tab_name": "✻ [ide-smoke] " + Path(target).name,
    })
    check("openDiff answers FILE_SAVED or DIFF_REJECTED",
          outcome in ("FILE_SAVED", "DIFF_REJECTED"), str(outcome))
    on_disk = Path(target).read_text()
    if outcome == "FILE_SAVED":
        check("accepted diff was written to disk", on_disk.endswith("ide-smoke touched this -->\n"))
        Path(target).write_text(original)
        print("        (restored the original file)")
    else:
        check("rejected diff left the file untouched", on_disk == original)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, help="lock file / server port")
    parser.add_argument("--open-diff", action="store_true",
                        help="also send openDiff (blocks until you click in EditMD)")
    args = parser.parse_args()

    try:
        port, lock = find_lock(args.port)
    except SmokeFailure as error:
        print(f"discovery failed: {error}", file=sys.stderr)
        return 2

    print(f"lock file  ~/.claude/ide/{port}.lock")
    print(f"ideName    {lock['ideName']}   transport {lock['transport']}   pid {lock['pid']}")
    print(f"workspace  {lock['workspaceFolders']}")

    print("\n· lock file")
    check("pid is alive", _pid_alive(lock["pid"]))
    check("authToken is 32 hex chars",
          len(lock["authToken"]) == 32 and all(c in "0123456789abcdef" for c in lock["authToken"]))
    problems = check_permissions(port)
    check("lock file 0600 / directory 0700", not problems, "; ".join(problems))

    try:
        ws = WebSocket("127.0.0.1", port, lock["authToken"])
    except SmokeFailure as error:
        print(f"\nconnect failed: {error}", file=sys.stderr)
        return 2
    check("upgrade accepted with the auth token", True)

    # The token is the only access control on a loopback port — prove it bites.
    try:
        WebSocket("127.0.0.1", port, "0" * 32).close()
        check("upgrade rejected without a valid token", False, "bad token was accepted!")
    except (SmokeFailure, OSError):
        check("upgrade rejected without a valid token", True)

    try:
        run(Client(ws), lock, args.open_diff)
    except SmokeFailure as error:
        print(f"\naborted: {error}", file=sys.stderr)
        FAILED.append(str(error))
    finally:
        ws.close()

    print(f"\n{PASSED} passed, {len(FAILED)} failed")
    for failure in FAILED:
        print(f"  · {failure}")
    return 1 if FAILED else 0


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


if __name__ == "__main__":
    sys.exit(main())
