#!/usr/bin/env python3
"""Exercise HashLink's HLD3 handshake and live patch-map refresh protocol."""

from __future__ import annotations

import argparse
import os
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass


class ProtocolError(RuntimeError):
    pass


class Reader:
    """Reads the HLD3 stream; a read that outlasts the deadline names the record it was waiting for."""

    def __init__(self, sock: socket.socket, deadline: float):
        self.sock = sock
        self.deadline = deadline
        self.waiting_for = "the HLD3 handshake"

    def expect(self, marker: bytes, waiting_for: str) -> None:
        self.waiting_for = f"{marker.decode()} ({waiting_for})"
        actual = self.read(4)
        if actual != marker:
            raise ProtocolError(f"expected {self.waiting_for}, got {actual!r}")

    def read(self, size: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < size:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise ProtocolError(f"timed out waiting for {self.waiting_for}")
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(size - len(chunks))
            except socket.timeout:
                raise ProtocolError(f"timed out waiting for {self.waiting_for}") from None
            if not chunk:
                raise ProtocolError(f"HLD3 stream ended while waiting for {self.waiting_for}")
            chunks.extend(chunk)
        return bytes(chunks)

    def i32(self) -> int:
        return struct.unpack("=i", self.read(4))[0]

    def pointer(self, size: int) -> int:
        raw = self.read(size)
        return int.from_bytes(raw, byteorder=sys.byteorder, signed=False)


@dataclass
class PatchRegion:
    address: int
    size: int
    retired: bool
    functions: list[int]


@dataclass
class ModuleMappings:
    identity: int
    revision: int
    regions: list[PatchRegion]


def read_function(reader: Reader, indexed: bool, stable: bool = False) -> int:
    function_index = reader.i32() if indexed else -1
    stable_id = reader.i32() if stable else function_index
    nops = reader.i32()
    _start = reader.i32()
    vars_size = reader.i32()
    large = reader.read(1)[0]
    if nops < 0 or vars_size < 0 or large not in (0, 1) or (stable and stable_id < 0):
        raise ProtocolError("invalid HLD3 function mapping")
    reader.read((nops + 1) * (4 if large else 2))
    reader.read(vars_size)
    if stable:
        span_count = reader.i32()
        if span_count not in (0, nops):
            raise ProtocolError("invalid HLD3 source-span count")
        for _ in range(span_count):
            file_index, line, column = reader.i32(), reader.i32(), reader.i32()
            end_line, end_column, _source_hash = reader.i32(), reader.i32(), reader.i32()
            start, end, flags = reader.i32(), reader.i32(), reader.i32()
            if file_index < 0 or line < 1 or column < 1 or end_line < line or end_column < 1 \
                    or not ((start == -1 and end == -1) or (start >= 0 and end >= start)) or flags < 0:
                raise ProtocolError("invalid HLD3 source span")
    return function_index


def read_patch_regions(reader: Reader, pointer_size: int) -> ModuleMappings:
    identity = reader.pointer(pointer_size)
    hlb_size = reader.i32()
    if hlb_size < 0:
        raise ProtocolError("invalid HLD3 module bytecode size")
    hlb = reader.read(hlb_size)
    if hlb and not hlb.startswith(b"HLB"):
        raise ProtocolError("invalid embedded HLD3 module bytecode")
    revision = reader.i32()
    reader.pointer(pointer_size)  # globals
    reader.pointer(pointer_size)  # runtime type table
    reader.pointer(pointer_size)  # initial JIT base
    if reader.i32() <= 0:
        raise ProtocolError("invalid HLD3 module JIT size")
    function_count = reader.i32()
    if function_count < 0:
        raise ProtocolError("invalid HLD3 module function count")
    for _ in range(function_count):
        read_function(reader, False, True)
    region_count = reader.i32()
    if revision < 1 or region_count < 0:
        raise ProtocolError("invalid HLD3 module revision or region count")
    regions: list[PatchRegion] = []
    for _ in range(region_count):
        address = reader.pointer(pointer_size)
        size = reader.i32()
        retired = reader.read(1)[0]
        function_count = reader.i32()
        if address == 0 or size <= 0 or retired not in (0, 1) or function_count <= 0:
            raise ProtocolError("invalid HLD3 patch region")
        functions = [read_function(reader, True, True) for _ in range(function_count)]
        if any(index < 0 for index in functions) or len(set(functions)) != len(functions):
            raise ProtocolError("invalid HLD3 patch function indices")
        snapshot_count = reader.i32()
        if snapshot_count < 0:
            raise ProtocolError("invalid HLD3 source snapshot count")
        hashes: set[int] = set()
        for _ in range(snapshot_count):
            source_hash, length = reader.i32(), reader.i32()
            if source_hash == 0 or length < 0 or source_hash in hashes:
                raise ProtocolError("invalid HLD3 source snapshot")
            content = reader.read(length)
            actual = 0x811C9DC5
            for byte in content:
                actual = ((actual ^ byte) * 16777619) & 0xFFFFFFFF
            if actual != source_hash & 0xFFFFFFFF:
                raise ProtocolError("invalid HLD3 source snapshot hash")
            hashes.add(source_hash)
        regions.append(PatchRegion(address, size, retired == 1, functions))
    return ModuleMappings(identity, revision, regions)


def read_handshake(reader: Reader) -> tuple[int, list[ModuleMappings]]:
    reader.expect(b"HLD3", "the handshake of a runtime started with HL_DEBUG_PROTOCOL=3")
    flags = reader.i32()
    pointer_size = 8 if flags & 1 else 4
    _hl_version = reader.i32()
    _pid = reader.i32()
    reader.pointer(pointer_size)
    for _ in range(8):
        if reader.i32() <= 0:
            raise ProtocolError("invalid HLD3 structure size")
    reader.i32()  # trampoline position
    module_count = reader.i32()
    if module_count <= 0:
        raise ProtocolError("HLD3 handshake contains no modules")
    modules: list[ModuleMappings] = []
    for _ in range(module_count):
        reader.pointer(pointer_size)  # globals
        reader.pointer(pointer_size)  # initial JIT base
        if reader.i32() <= 0:
            raise ProtocolError("invalid initial JIT region size")
        reader.pointer(pointer_size)  # type table
        function_count = reader.i32()
        if function_count < 0:
            raise ProtocolError("invalid HLD3 function count")
        for _ in range(function_count):
            read_function(reader, False)
        modules.append(read_patch_regions(reader, pointer_size))
    return pointer_size, modules


def read_refresh(reader: Reader, pointer_size: int) -> list[ModuleMappings]:
    reader.expect(b"MAP3", "the refresh answering R")
    module_count = reader.i32()
    if module_count <= 0:
        raise ProtocolError("MAP3 refresh contains no modules")
    return [read_patch_regions(reader, pointer_size) for _ in range(module_count)]


def connect(port: int, process: subprocess.Popen[str], timeout: float) -> socket.socket:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("HashLink exited before the debugger connected")
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=0.2)
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("timed out connecting to the HashLink debug port")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("module", help="HL module path")
    parser.add_argument("--hl", required=True, help="HashLink executable")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

    environment = os.environ.copy()
    environment["HL_DEBUG_PROTOCOL"] = "3"
    process = subprocess.Popen(
        [args.hl, "--debug", str(port), "--debug-wait", args.module],
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    sock: socket.socket | None = None
    try:
        # One deadline for the whole exchange: each read below names what it waits for when the deadline passes.
        deadline = time.monotonic() + args.timeout
        sock = connect(port, process, args.timeout)
        reader = Reader(sock, deadline)
        pointer_size, initial = read_handshake(reader)
        initial_revisions = {module.identity: module.revision for module in initial}
        observed: ModuleMappings | None = None
        # A releases --debug-wait without racing a redundant live snapshot.
        sock.sendall(b"A")
        reader.expect(b"ACK3", "the acknowledgement releasing --debug-wait")
        # The runtime sends REV3 when the probe loads its module and again when it patches it, and holds the probe until A
        # acknowledges, so each revision is read here before the probe goes on; no wait of the probe's own is involved.
        while observed is None:
            reader.expect(b"REV3", "a module revision; the probe compiles under -debug before loading and before each patch")
            reader.pointer(pointer_size)
            if reader.i32() <= 0:
                raise ProtocolError("invalid REV3 revision")
            sock.sendall(b"R")
            for module in read_refresh(reader, pointer_size):
                if module.regions and module.revision > initial_revisions.get(module.identity, 0):
                    observed = module
                    break
            sock.sendall(b"A")
        sock.sendall(b"Q")
        sock.close()
        sock = None
        try:
            output, _ = process.communicate(timeout=max(deadline - time.monotonic(), 1))
        except subprocess.TimeoutExpired:
            raise RuntimeError("timed out waiting for HashLink to exit once the debugger quit") from None
        if process.returncode != 0:
            raise RuntimeError(f"HashLink exited with {process.returncode}:\n{output}")
        active = sum(not region.retired for region in observed.regions)
        functions = sum(len(region.functions) for region in observed.regions)
        print(
            f"PASS: HLD3 refreshed revision {observed.revision} with "
            f"{active} active region(s) and {functions} mapped function(s)"
        )
        return 0
    except ProtocolError as error:
        # The probe's own output says why it stopped talking, when it crashed.
        process.kill()
        output, _ = process.communicate()
        raise ProtocolError(f"{error}\nHashLink output:\n{output}") from None
    finally:
        if sock is not None:
            sock.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProtocolError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
