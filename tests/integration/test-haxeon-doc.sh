#!/usr/bin/env bash
# haxeon doc (docs/reference/cli/build-run.md): a library package with no entry is described; its internal package is not,
# nor is its dependency, though the types its API refers to are in the description; --output chooses the file.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon=$root/scripts/haxeon
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-doc.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export HAXEON_COMPILER_SERVER=0

mkdir -p "$work/shapes/src/shapes" "$work/library/src/library/internal"
cat > "$work/shapes/haxeon.toml" <<'TOML'
version = 1
sourceRoots = ["src"]

[package]
name = "shapes"
TOML
cat > "$work/shapes/src/shapes/Size.hx" <<'HAXE'
package shapes;

typedef Size = {
	var width:Int;
	var height:Int;
}
HAXE
cat > "$work/library/haxeon.toml" <<'TOML'
version = 1
sourceRoots = ["src"]

[package]
name = "library"

[dependencies]
shapes = { path = "../shapes" }
TOML
cat > "$work/library/src/library/Panel.hx" <<'HAXE'
package library;

import library.internal.Layout;
import shapes.Size;

/** A panel of a fixed size. */
class Panel {
	public final size:Size;

	public function new(size:Size) {
		this.size = size;
	}

	public function area():Int {
		return Layout.area(size);
	}
}
HAXE
cat > "$work/library/src/library/internal/Layout.hx" <<'HAXE'
package library.internal;

class Layout {
	public static function area(size:shapes.Size):Int {
		return size.width * size.height;
	}
}
HAXE

cd "$work/library"
"$haxeon" doc
"$haxeon" doc --output "$work/api.json"
cmp build/api.json "$work/api.json"
python3 - "$work/api.json" <<'PY'
import json
import sys

model = json.load(open(sys.argv[1]))
assert model["described"] == ["library.Panel"], model["described"]
types = {entry["path"]: entry for entry in model["types"]}
assert "shapes.Size" in types, "the dependency type the API names is missing"
panel = types["library.Panel"]
constructor = next(member for member in panel["members"] if member["kind"] == "constructor")
assert constructor["arguments"][0]["type"] == {"kind": "named", "path": "shapes.Size", "arguments": []}, constructor
assert panel["source"]["documentation"]["markdown"] == "A panel of a fixed size."
# Each source belongs to its package, at a path relative to the package's root: nothing names this machine's directories.
assert (panel["package"], panel["source"]["position"]["file"]) == ("library", "src/library/Panel.hx"), panel["source"]
assert (types["shapes.Size"]["package"], types["shapes.Size"]["source"]["position"]["file"]) == ("shapes", "src/shapes/Size.hx")
assert '"/' not in open(sys.argv[1]).read().replace('"/"', ""), "an absolute path is in the description"
PY
echo "PASS: haxeon doc describes a library's own public modules, without an entry"
