#!/usr/bin/env python3
"""Size and instruction statistics of a HashLink module (.hl), to see what makes compiled code big or slow to load.

    scripts/hl-stat.py MODULE                       sections, counts and sizes
    scripts/hl-stat.py MODULE --ops [N]             the N most frequent opcodes (default 30)
    scripts/hl-stat.py MODULE --top N               the N largest functions, with instruction and register counts
    scripts/hl-stat.py MODULE --dump NAME [--index I]   one function's instructions (NAME as --top prints it)
    scripts/hl-stat.py MODULE --around OPCODE       the opcodes before and after OPCODE, by count
    scripts/hl-stat.py MODULE --sections            the debug sections and their sizes

Two modules side by side (a stock-Haxe-built and a Haxeon-built one) answer most "why is ours bigger" questions. Opcode
arities come from vendor/hashlink/src/opcodes.h; function names from the module's function identity section (HLB 7+), else
from class prototypes and bindings (older modules, such as stock Haxe's). The format readers mirror vendor/hashlink/src/code.c.
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_opcodes():
    text = open(os.path.join(ROOT, "vendor", "hashlink", "src", "opcodes.h")).read()
    # The table is between OP_BEGIN and OP_END; the macro definitions above it look like entries.
    text = text[text.index("\nOP_BEGIN"):text.index("\nOP_END")]
    result = []
    for name, a, b, c in re.findall(r"OP\((\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)", text):
        if b == "AR":
            count = -1 if c == "VAR_ARGS" else int(c)
        else:
            count = 3 if c != "X" else (2 if b != "X" else (1 if a != "X" else 0))
        result.append((name, count))
    return result


OPCODES = load_opcodes()


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def byte(self):
        value = self.data[self.pos]
        self.pos += 1
        return value

    def index(self):
        b = self.byte()
        if not b & 0x80:
            return b
        if not b & 0x40:
            value = ((b & 0x1F) << 8) | self.byte()
        else:
            value = ((b & 0x1F) << 24) | (self.byte() << 16) | (self.byte() << 8) | self.byte()
        return -value if b & 0x20 else value

    def i32(self):
        value = int.from_bytes(self.data[self.pos:self.pos + 4], "little")
        self.pos += 4
        return value

    def strings(self, count):
        size = self.i32()
        start = self.pos
        self.pos += size
        result, cursor = [], start
        for _ in range(count):
            length = self.index()
            result.append(self.data[cursor:cursor + length].decode("utf-8", "replace"))
            cursor += length + 1
        return result

    def sized_string(self):
        length = self.index()
        value = self.data[self.pos:self.pos + length].decode("utf-8", "replace")
        self.pos += length
        return value


class Function:
    def __init__(self, index, size, ops, registers, start, ops_start):
        self.index, self.size, self.ops, self.registers = index, size, ops, registers
        self.start, self.ops_start = start, ops_start
        self.name = None


def read_opcode(r):
    op = r.byte()
    name, count = OPCODES[op]
    args = []
    if count in (0, 1, 2, 3):
        args = [r.index() for _ in range(count)]
    elif count == 4:
        args = [r.index() for _ in range(4)]
    elif count == -1:
        if name == "OSwitch":
            args = [r.index(), r.index()]
            args += [r.index() for _ in range(args[1])]
            args.append(r.index())
        else:
            args = [r.index(), r.index(), r.byte()]
            args += [r.index() for _ in range(args[2])]
    else:
        args = [r.index() for _ in range(count)]
    return name, args


def read_module(path):
    r = Reader(open(path, "rb").read())
    if r.data[:3] != b"HLB":
        raise SystemExit(f"{path}: not a HashLink module")
    r.pos = 3
    version = r.byte()
    flags = r.index()
    nints, nfloats, nstrings = r.index(), r.index(), r.index()
    nbytes = r.index() if version >= 5 else 0
    ntypes, nglobals, nnatives, nfunctions = r.index(), r.index(), r.index(), r.index()
    nconstants = r.index() if version >= 4 else 0
    r.index()
    sizes = collections.OrderedDict()
    start = r.pos
    r.pos += 4 * nints + 8 * nfloats
    strings = r.strings(nstrings)
    sizes["strings"] = r.pos - start
    if version >= 5:
        size = r.i32()
        r.pos += size
        for _ in range(nbytes):
            r.index()
    if flags & 1:
        start = r.pos
        r.strings(r.index())
        sizes["debug files"] = r.pos - start
    start = r.pos
    names = {}
    for _ in range(ntypes):
        kind = r.byte()
        if kind in (10, 20):  # function, method
            for _ in range(r.byte()):
                r.index()
            r.index()
        elif kind in (11, 21):  # object, struct
            owner = strings[r.index()].lstrip("$")
            r.index()
            r.index()
            nfields, nproto, nbindings = r.index(), r.index(), r.index()
            fields = []
            for _ in range(nfields):
                fields.append(strings[r.index()])
                r.index()
            for _ in range(nproto):
                method = strings[r.index()]
                names.setdefault(r.index(), owner + "." + method)
                r.index()
            for _ in range(nbindings):
                field, function = r.index(), r.index()
                names.setdefault(function, owner + "." + (fields[field] if 0 <= field < len(fields) else "<binding>"))
        elif kind == 15:  # virtual
            if version >= 8:
                r.index()
            for _ in range(r.index()):
                r.index()
                r.index()
        elif kind == 17:  # abstract
            r.index()
        elif kind == 18:  # enum
            r.index()
            r.index()
            for _ in range(r.index()):
                r.index()
                for _ in range(r.index()):
                    r.index()
        elif kind == 24:  # enum tag
            r.index()
            for _ in range(r.index()):
                r.index()
        elif kind in (14, 19, 22):  # ref, null, packed
            r.index()
    sizes["types"] = r.pos - start
    start = r.pos
    for _ in range(nglobals):
        r.index()
    for _ in range(nnatives):
        r.index(), r.index(), r.index(), r.index()
    sizes["globals and natives"] = r.pos - start
    functions = []
    register_bytes = op_bytes = debug_bytes = 0
    opcount = collections.Counter()
    for _ in range(nfunctions):
        function_start = r.pos
        r.index()
        index, nregs, nops = r.index(), r.index(), r.index()
        mark = r.pos
        for _ in range(nregs):
            r.index()
        register_bytes += r.pos - mark
        mark = r.pos
        for _ in range(nops):
            name, _ = read_opcode(r)
            opcount[name] += 1
        op_bytes += r.pos - mark
        mark = r.pos
        if flags & 1:
            position = 0
            while position < nops:
                c = r.byte()
                if c & 1:
                    r.byte()
                elif c & 2:
                    position += (c >> 2) & 15
                elif c & 4:
                    position += 1
                else:
                    r.byte()
                    r.byte()
                    position += 1
            if version >= 3:
                for _ in range(r.index()):
                    r.index()
                    r.index()
                    if version >= 6:
                        r.index()
        debug_bytes += r.pos - mark
        functions.append(Function(index, r.pos - function_start, nops, nregs, function_start, 0))
    sizes["function registers"] = register_bytes
    sizes["function instructions"] = op_bytes
    sizes["function debug lines"] = debug_bytes
    start = r.pos
    for _ in range(nconstants):
        r.index()
        for _ in range(r.index()):
            r.index()
    sizes["constants"] = r.pos - start
    sections = []
    if version >= 7:
        for _ in range(r.index()):
            kind, section_version, _, size = r.index(), r.index(), r.index(), r.index()
            sections.append((kind, section_version, r.pos, size))
            if kind == 1:  # function identities: the names the VM uses for traces and the profiler
                s = Reader(r.data)
                s.pos = r.pos
                for _ in range(s.index()):
                    s.index()
                    function = s.index()
                    names[function] = s.sized_string()
                    s.sized_string()
                    s.sized_string()
                    for _ in range(4):
                        s.index()
            r.pos += size
        sizes["debug sections"] = sum(section[3] for section in sections)
    for function in functions:
        function.name = names.get(function.index, f"<function {function.index}>")
    return dict(path=path, version=version, size=len(r.data), sizes=sizes, functions=functions, opcount=opcount,
                sections=sections, data=r.data)


def function_instructions(module, function):
    r = Reader(module["data"])
    r.pos = function.start
    r.index()
    r.index()
    nregs, nops = r.index(), r.index()
    registers = [r.index() for _ in range(nregs)]
    return registers, [read_opcode(r) for _ in range(nops)]


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        raise SystemExit(__doc__)
    module = read_module(args[0])
    functions = module["functions"]
    total_ops = sum(f.ops for f in functions)
    total_registers = sum(f.registers for f in functions)
    print(f"{os.path.basename(module['path'])}: HLB {module['version']}, {module['size']} bytes, {len(functions)} functions, "
          f"{total_ops} instructions, {total_registers} registers")
    for name, size in module["sizes"].items():
        print(f"  {name:24} {size:10}")
    if "--ops" in args:
        position = args.index("--ops")
        count = int(args[position + 1]) if position + 1 < len(args) and args[position + 1].isdigit() else 30
        for name, n in module["opcount"].most_common(count):
            print(f"  {name:16} {n:9}")
    if "--top" in args:
        count = int(args[args.index("--top") + 1])
        for f in sorted(functions, key=lambda f: -f.size)[:count]:
            print(f"  {f.size:8} bytes {f.ops:6} instructions {f.registers:5} registers  {f.name}")
    if "--dump" in args:
        name = args[args.index("--dump") + 1]
        matches = [f for f in functions if f.name == name]
        if "--index" in args:
            wanted = int(args[args.index("--index") + 1])
            matches = [f for f in matches if f.index == wanted]
        if not matches:
            raise SystemExit(f"no function named {name}")
        for f in matches:
            registers, ops = function_instructions(module, f)
            print(f"function {f.name} (index {f.index}): {f.registers} registers, {f.ops} instructions")
            for position, (op, operands) in enumerate(ops):
                print(f"  {position:5} {op[1:]:14} {operands}")
    if "--around" in args:
        wanted = args[args.index("--around") + 1]
        wanted = wanted if wanted.startswith("O") else "O" + wanted
        before, after = collections.Counter(), collections.Counter()
        for f in functions:
            _, ops = function_instructions(module, f)
            for position, (op, _) in enumerate(ops):
                if op == wanted:
                    if position > 0:
                        before[ops[position - 1][0]] += 1
                    if position + 1 < len(ops):
                        after[ops[position + 1][0]] += 1
        print("  before " + wanted + ": " + ", ".join(f"{k[1:]} {v}" for k, v in before.most_common(12)))
        print("  after  " + wanted + ": " + ", ".join(f"{k[1:]} {v}" for k, v in after.most_common(12)))
    if "--sections" in args:
        for kind, version, offset, size in module["sections"]:
            print(f"  debug section kind {kind} version {version}: {size} bytes at {offset}")


main()
