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
    def __init__(self, sock: socket.socket):
        self.sock = sock

    def read(self, size: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < size:
            chunk = self.sock.recv(size - len(chunks))
            if not chunk:
                raise ProtocolError("unexpected end of HLD3 stream")
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


def read_function(reader: Reader, indexed: bool) -> int:
    function_index = reader.i32() if indexed else -1
    nops = reader.i32()
    _start = reader.i32()
    vars_size = reader.i32()
    large = reader.read(1)[0]
    if nops < 0 or vars_size < 0 or large not in (0, 1):
        raise ProtocolError("invalid HLD3 function mapping")
    reader.read((nops + 1) * (4 if large else 2))
    reader.read(vars_size)
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
        read_function(reader, False)
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
        functions = [read_function(reader, True) for _ in range(function_count)]
        if any(index < 0 for index in functions) or len(set(functions)) != len(functions):
            raise ProtocolError("invalid HLD3 patch function indices")
        regions.append(PatchRegion(address, size, retired == 1, functions))
    return ModuleMappings(identity, revision, regions)


def read_handshake(reader: Reader) -> tuple[int, list[ModuleMappings]]:
    if reader.read(4) != b"HLD3":
        raise ProtocolError("runtime did not negotiate HLD3")
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


def read_refresh(reader: Reader, pointer_size: int, marker: bytes | None = None) -> list[ModuleMappings]:
    if (marker if marker is not None else reader.read(4)) != b"MAP3":
        raise ProtocolError("missing MAP3 refresh marker")
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
        sock = connect(port, process, args.timeout)
        sock.settimeout(args.timeout)
        reader = Reader(sock)
        pointer_size, initial = read_handshake(reader)
        initial_revisions = {module.identity: module.revision for module in initial}
        deadline = time.monotonic() + args.timeout
        observed: ModuleMappings | None = None
        # A releases --debug-wait without racing a redundant live snapshot.
        sock.sendall(b"A")
        if reader.read(4) != b"ACK3":
            raise ProtocolError("missing initial ACK3")
        while time.monotonic() < deadline and process.poll() is None:
            marker = reader.read(4)
            if marker != b"REV3":
                raise ProtocolError("missing REV3 notification")
            reader.pointer(pointer_size)
            if reader.i32() <= 0:
                raise ProtocolError("invalid REV3 revision")
            sock.sendall(b"R")
            marker = reader.read(4)
            for module in read_refresh(reader, pointer_size, marker):
                if module.regions and module.revision > initial_revisions.get(module.identity, 0):
                    observed = module
                    break
            sock.sendall(b"A")
            if observed is not None:
                break
            time.sleep(0.005)
        if observed is None:
            raise ProtocolError("no revised module with patch JIT mappings was observed")
        sock.sendall(b"Q")
        sock.close()
        sock = None
        output, _ = process.communicate(timeout=args.timeout)
        if process.returncode != 0:
            raise RuntimeError(f"HashLink exited with {process.returncode}:\n{output}")
        active = sum(not region.retired for region in observed.regions)
        functions = sum(len(region.functions) for region in observed.regions)
        print(
            f"PASS: HLD3 refreshed revision {observed.revision} with "
            f"{active} active region(s) and {functions} mapped function(s)"
        )
        return 0
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
