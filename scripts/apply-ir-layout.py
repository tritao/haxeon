#!/usr/bin/env python3
"""Moves the modules of src/compiler/ir into the packages a layout file names, in a Haxeon checkout.

    python3 apply-ir-layout.py [--layout ir-layout.txt] [--no-format] [--haxeon LAUNCHER] CHECKOUT

For every `Module destination.package` line of the layout whose module is still at src/compiler/ir/Module.hx:
  - `git mv` it to the destination's directory and rewrites its `package` line;
then, over the whole checkout (every tracked text file but vendor/ and bootstrap/):
  - rewrites `compiler.ir.Module` (imports, `using`, `@:allow`, fully qualified references, strings) and
    `compiler/ir/Module.hx` / `ir/Module.hx` paths to the new places;
  - adds the imports a file of a `compiler.ir` package needs now that a module it used unqualified (same package) lives in
    another package;
  - runs `haxeon lint --fix` and `haxeon fmt` on every Haxe file it changed, which sorts the imports as the pre-push hook expects.

It is idempotent: modules already in place are not moved, rewrites only match the old names, and an import is only added
when the file has none for that name. Modules of compiler.ir that the layout does not list stay and are reported; layout
modules missing from the checkout are reported too. Nothing is committed.
"""
import argparse
import os
import re
import subprocess
import sys
import time

OLD = "compiler.ir"


def read_layout(path):
    layout = {}
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2 or not re.fullmatch(r"[A-Z]\w*", parts[0]) or not re.fullmatch(r"[a-z]\w*(\.[a-z]\w*)*", parts[1]):
            sys.exit(f"{path}:{number}: expected `Module destination.package`, got {line!r}")
        if parts[0] in layout:
            sys.exit(f"{path}:{number}: {parts[0]} is listed twice")
        layout[parts[0]] = parts[1]
    return layout


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), check=True, capture_output=True, text=True).stdout


def module_path(root, package, module):
    return os.path.join(root, "src", *package.split("."), module + ".hx")


COMMENT_OR_STRING = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\\n])*"', re.S)


def code_only(text):
    """The text without comments and double-quoted strings (single-quoted ones interpolate, so they stay)."""
    return COMMENT_OR_STRING.sub(lambda m: "\n" * m.group(0).count("\n"), text)


IMPORT = re.compile(r"^\s*(import|using)\s+([\w.]+(?:\.\*)?)(?:\s+(?:as|in)\s+(\w+))?\s*;", re.M)
DECLARATION = re.compile(r"\b(?:class|interface|enum|abstract|typedef)\s+([A-Z]\w*)")
PACKAGE = re.compile(r"^\s*package\s+([\w.]*)\s*;", re.M)


def added_imports(text, own_module, layout):
    """The `import` lines a file of a compiler.ir package needs for the moved modules it names unqualified."""
    code = code_only(text)
    match = PACKAGE.search(code)
    package = match.group(1) if match else ""
    visible, wildcards = set(), set()
    for kind, path, alias in IMPORT.findall(code):
        if path.endswith(".*"):
            wildcards.add(path[:-2])
        else:
            visible.add(alias or path.rsplit(".", 1)[-1])
    visible |= set(DECLARATION.findall(code))
    visible.add(own_module)
    body = IMPORT.sub("", PACKAGE.sub("", code))
    used = set(re.findall(r"(?<!\w)(?<!\w\.)([A-Z]\w*)(?!\w)", body))
    lines = []
    for name in sorted(used & set(layout)):
        destination = layout[name]
        if destination == package or name in visible or destination in wildcards:
            continue
        lines.append(f"import {destination}.{name};")
    return lines


def unqualify_subtypes(text, package, subtypes, layout):
    """`Module.SubType` finds Module through the file's package only, not through its imports: a file that named a sub-type
    that way from the same package now imports the sub-type and names it alone, or names it fully when the short name is taken."""
    code = code_only(text)
    taken = set(DECLARATION.findall(code))
    imported = {}
    for kind, path, alias in IMPORT.findall(code):
        if not path.endswith(".*"):
            imported[alias or path.rsplit(".", 1)[-1]] = path
    lines = []

    def replace(match):
        module, sub = match.group(1), match.group(2)
        destination = layout[module]
        if destination == package or sub not in subtypes.get(module, ()):
            return match.group(0)
        full = f"{destination}.{module}.{sub}"
        if sub in taken or imported.get(sub, full) != full:
            return full
        if sub not in imported:
            imported[sub] = full
            lines.append(f"import {full};")
        return sub

    names = "|".join(sorted(layout, key=len, reverse=True))
    pattern = re.compile(r"(?<![\w$])(?<!\w\.)(" + names + r")\.([A-Z]\w*)(?!\w)")
    # Only outside comments and strings: rewrite the code spans between them.
    out, last = [], 0
    for match in COMMENT_OR_STRING.finditer(text):
        out.append(pattern.sub(replace, text[last:match.start()]))
        out.append(match.group(0))
        last = match.end()
    out.append(pattern.sub(replace, text[last:]))
    result = "".join(out)
    return result, lines


class Exposure:
    """The short names an import makes visible: types, enum constructors and enum abstract values, read from the sources."""

    def __init__(self, root):
        self.roots = [os.path.join(root, d) for d in ("src", "lib/haxeon-io", "stdlib", ".tools/haxe/std")]
        self.modules = {}

    def module(self, parts):
        key = ".".join(parts)
        if key not in self.modules:
            info = None
            for base in self.roots:
                path = os.path.join(base, *parts) + ".hx"
                if os.path.isfile(path):
                    info = self.parse(open(path, encoding="utf-8", errors="replace").read())
                    break
            self.modules[key] = info
        return self.modules[key]

    @staticmethod
    def parse(text):
        code = code_only(text)
        types = {}
        for match in re.finditer(r"\b(enum\s+abstract|enum|class|interface|abstract|typedef)\s+([A-Z]\w*)", code):
            kind, name = match.group(1), match.group(2)
            members = set()
            if kind.startswith("enum"):
                start = code.find("{", match.end())
                depth, at = 0, start
                while 0 <= at < len(code):
                    depth += {"{": 1, "}": -1}.get(code[at], 0)
                    if depth == 0:
                        break
                    at += 1
                body = code[start + 1:at]
                # Only the declarations at the top level of the body.
                flat, depth = [], 0
                for char in body:
                    if char in "{(":
                        depth += 1
                    elif char in "})":
                        depth -= 1
                    elif depth == 0:
                        flat.append(char)
                flat = "".join(flat)
                if kind == "enum":
                    members = set(re.findall(r"(?:^|[;}])\s*(?:@:?\w+\s*)*([A-Z]\w*)\s*(?=[;(<])", flat, re.M))
                else:
                    members = set(re.findall(r"\b(?:var|final)\s+([A-Z]\w*)", flat))
            types.setdefault(name, set()).update(members)
        return types

    def names(self, path, alias):
        """The names `import path [as alias]` makes visible, each with what it names, or None when they cannot be known (a
        wildcard, an unknown module)."""
        if path.endswith(".*"):
            return None
        parts = path.split(".")
        for split in range(len(parts), 0, -1):
            if not parts[split - 1][:1].isupper():
                continue
            types = self.module(parts[:split])
            if types is None:
                continue
            module, rest = ".".join(parts[:split]), parts[split:]

            def of(name):
                result = {name: f"{module}.{name}"}
                result.update({member: f"{module}.{name}.{member}" for member in types[name]})
                return result

            if not rest:
                result = {}
                for name in types:
                    result.update(of(name))
            elif len(rest) == 1 and rest[0] in types:
                result = of(rest[0])
            else:
                result = {rest[-1]: path}
            if alias:
                result[alias] = result.pop(parts[-1], path)
            return result
        return None


def insert_imports(text, lines, exposure):
    """Puts the added `lines` where they mean what the same-package lookup they replace meant. That lookup came after every
    import, so where a name an added import makes visible (a type, an enum constructor, an enum abstract value) is also made
    visible by an import the file has, the added imports go in their own run before the others, which keeps the file's imports
    winning. Otherwise they join the file's first run of imports, and `lint --fix` sorts them into it."""
    code = code_only(text)
    added, existing = {}, {}
    for line in lines:
        kind, path, alias = IMPORT.match(line).groups()
        added.update(exposure.names(path, alias) or {})
    unknown = False
    for kind, path, alias in IMPORT.findall(code):
        names = exposure.names(path, alias)
        if names is None:
            unknown = True
        else:
            existing.update(names)
    first = re.search(r"^(import|using)\s", text, re.M)
    conditional = re.search(r"^\s*#if\b", text[: first.start()] if first else "", re.M)
    block = "".join(line + "\n" for line in lines)
    if first and not conditional:
        body = IMPORT.sub("", PACKAGE.sub("", code))
        used = set(re.findall(r"(?<!\w)(?<!\.)([A-Z]\w*)(?!\w)", body))
        separate = unknown or any(name in existing and existing[name] != added[name] for name in used & set(added))
        return text[: first.start()] + block + ("\n" if separate else "") + text[first.start():]
    package = re.search(r"^\s*package\s+[\w.]*\s*;[^\n]*\n", text, re.M)
    at = package.end() if package else 0
    return text[:at] + "\n" + block + text[at:]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout")
    parser.add_argument("--layout", default=os.path.join(here, "ir-layout.txt"))
    parser.add_argument("--no-format", action="store_true", help="skip haxeon lint --fix and fmt")
    parser.add_argument("--haxeon", help="the haxeon launcher for lint and fmt (default: the checkout's scripts/haxeon, as built)")
    options = parser.parse_args()
    root = os.path.abspath(options.checkout)
    started = time.time()
    layout = read_layout(options.layout)
    ir = os.path.join(root, "src", "compiler", "ir")

    moved, missing = [], []
    for module, destination in layout.items():
        source, target = module_path(root, OLD, module), module_path(root, destination, module)
        if destination == OLD:
            continue
        if os.path.exists(source):
            if os.path.exists(target):
                sys.exit(f"both {source} and {target} exist")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            git(root, "mv", os.path.relpath(source, root), os.path.relpath(target, root))
            moved.append(module)
        elif not os.path.exists(target):
            missing.append(module)
    present = {m: d for m, d in layout.items() if m not in missing and d != OLD}
    unplaced = sorted(f[:-3] for f in os.listdir(ir) if f.endswith(".hx") and f[:-3] not in present)

    subtypes = {}
    for module, destination in present.items():
        code = code_only(open(module_path(root, destination, module), encoding="utf-8").read())
        subtypes[module] = set(DECLARATION.findall(code)) - {module}

    # A sub-type's class path is its package and its name (`@:allow(compiler.ir.SubType)`), so it moves with its module.
    owners = dict(present)
    for module, types in subtypes.items():
        for name in types:
            if name in owners and owners[name] != present[module]:
                sys.exit(f"{name} names both a module and a sub-type of {module}, in different packages")
            owners.setdefault(name, present[module])
    qualified = re.compile(r"(?<![\w$])(?<!\w\.)compiler\.ir\.(" + "|".join(sorted(owners, key=len, reverse=True)) + r")(?!\w)")
    names = "|".join(sorted(present, key=len, reverse=True))
    full_path = re.compile(r"(?<![\w])compiler/ir/(" + names + r")\.hx")
    short_path = re.compile(r"(?<![\w/.])ir/(" + names + r")\.hx")

    def relative_dir(destination):  # under src/compiler/
        return "/".join(destination.split(".")[1:])

    exposure = Exposure(root)
    changed_haxe = set()
    files = [f for f in git(root, "ls-files", "-z").split("\0") if f]
    for relative in files:
        if relative.startswith(("vendor/", "bootstrap/", "out/")) or "/vendor/" in relative:
            continue
        path = os.path.join(root, relative)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        if "\0" in text:
            continue
        new = qualified.sub(lambda m: f"{owners[m.group(1)]}.{m.group(1)}", text)
        new = full_path.sub(lambda m: f"compiler/{relative_dir(present[m.group(1)])}/{m.group(1)}.hx", new)
        new = short_path.sub(lambda m: f"{relative_dir(present[m.group(1)])}/{m.group(1)}.hx", new)
        module = os.path.basename(relative)[:-3] if relative.endswith(".hx") else None
        if module in present and relative == os.path.relpath(module_path(root, present[module], module), root):
            new = PACKAGE.sub(f"package {present[module]};", new, count=1)
        if relative.endswith(".hx"):
            match = PACKAGE.search(code_only(new))
            package = match.group(1) if match else ""
            if package == OLD or package.startswith(OLD + ".") or module in present:
                new, lines = unqualify_subtypes(new, package, subtypes, present)
                lines += added_imports(new, module, present)
                if lines:
                    new = insert_imports(new, lines, exposure)
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
            if relative.endswith(".hx"):
                changed_haxe.add(relative)

    if changed_haxe and not options.no_format:
        haxeon = options.haxeon or os.path.join(root, "scripts", "haxeon")
        # The CLI as built before the move: rebuilding it here would compile the sources half way through the change.
        os.environ["HAXEON_NATIVE_READY"] = "1"
        batch = sorted(changed_haxe)
        for start in range(0, len(batch), 200):
            chunk = batch[start:start + 200]
            # A second pass sorts a run the first one changed by removing an import.
            for _ in range(2):
                subprocess.run([haxeon, "lint", "--fix"] + chunk, cwd=root, capture_output=True)
            result = subprocess.run([haxeon, "fmt"] + chunk, cwd=root, capture_output=True, text=True)
            if result.returncode != 0:
                sys.stderr.write(result.stdout + result.stderr)
                sys.exit("haxeon fmt failed")
        check = subprocess.run([haxeon, "lint"] + batch, cwd=root, capture_output=True, text=True)
        if check.returncode != 0:
            sys.stderr.write(check.stdout + check.stderr)
            sys.exit("haxeon lint still reports problems")

    print(f"moved {len(moved)} modules, {len(present)} in place, {len(changed_haxe)} Haxe files changed, "
          f"{time.time() - started:.1f} s")
    if missing:
        print("layout modules not in the checkout (deleted or renamed upstream?): " + ", ".join(missing))
    if unplaced:
        print("modules left in compiler.ir (not in the layout): " + ", ".join(unplaced))


if __name__ == "__main__":
    main()
