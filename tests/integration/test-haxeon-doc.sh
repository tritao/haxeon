#!/usr/bin/env bash
# haxeon doc (docs/reference/cli/build-run.md): a library package with no entry is described, its internal declarations
# marked so, but not its dependency, though the types its API refers to are in the description; --output chooses the file.
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

internal class Layout {
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
assert model["described"] == ["library.Panel", "library.internal.Layout"], model["described"]
types = {entry["path"]: entry for entry in model["types"]}
assert "shapes.Size" in types, "the dependency type the API names is missing"
assert types["library.internal.Layout"]["source"]["visibility"] == "internal", types["library.internal.Layout"]["source"]
panel = types["library.Panel"]
constructor = next(member for member in panel["members"] if member["kind"] == "constructor")
assert constructor["arguments"][0]["type"] == {"kind": "named", "path": "shapes.Size", "arguments": []}, constructor
assert panel["source"]["documentation"]["markdown"] == "A panel of a fixed size."
# Each source belongs to its package, at a path relative to the package's root: nothing names this machine's directories.
assert (panel["package"], panel["source"]["position"]["file"]) == ("library", "src/library/Panel.hx"), panel["source"]
assert (types["shapes.Size"]["package"], types["shapes.Size"]["source"]["position"]["file"]) == ("shapes", "src/shapes/Size.hx")
assert '"/' not in open(sys.argv[1]).read().replace('"/"', ""), "an absolute path is in the description"
PY

# A package that requires its documentation fails check and doc on each undocumented declaration of its own API: not on
# its dependency's, nor its internal ones, nor a member that inherits the comment of the one it implements.
mkdir -p "$work/measured/src/measured"
cat > "$work/measured/haxeon.toml" <<'TOML'
version = 1
sourceRoots = ["src"]

[package]
name = "measured"
documentation = "required"

[dependencies]
shapes = { path = "../shapes" }
TOML
cat > "$work/measured/src/measured/Measured.hx" <<'HAXE'
package measured;

/** Something with an area. */
interface Measured {
	/** The area, in square units. */
	function area():Int;
}
HAXE
cat > "$work/measured/src/measured/Box.hx" <<'HAXE'
package measured;

import shapes.Size;

/** A box of a fixed size. */
class Box implements Measured {
	public final size:Size;

	/** A box of `size`. */
	public function new(size:Size) {
		this.size = size;
	}

	public function area():Int {
		return Corner.count() * size.width * size.height;
	}

	public static function unit():Box {
		return new Box({width: 1, height: 1});
	}
}

internal class Corner {
	public static function count():Int {
		return 1;
	}
}
HAXE
cd "$work/measured"
for command in check doc; do
	if "$haxeon" "$command" --color=never --diagnostic-format=short > "$work/$command.log" 2>&1; then
		cat "$work/$command.log" >&2
		echo "FAIL: haxeon $command passed a package that requires documentation with undocumented declarations" >&2
		exit 1
	fi
	reported=$(grep -oE 'E1032: Public [a-z]+ "[A-Za-z.]+"' "$work/$command.log" | sort | tr '\n' ';')
	if [[ "$reported" != 'E1032: Public field "Box.size";E1032: Public method "Box.unit";' ]]; then
		cat "$work/$command.log" >&2
		echo "FAIL: haxeon $command reported \"$reported\", not Box.size and Box.unit" >&2
		exit 1
	fi
done
sed -i 's|^	public final size:Size;|	/** The size it was made with. */\n	public final size:Size;|; s|^	public static function unit|	/** A box of one by one. */\n	public static function unit|' src/measured/Box.hx
"$haxeon" check
"$haxeon" doc
python3 - build/api.json <<'PY'
import json
import sys

model = json.load(open(sys.argv[1]))
box = next(entry for entry in model["types"] if entry["path"] == "measured.Box")
area = next(member for member in box["members"] if member["name"] == "area")
assert area["source"]["documentation"] is None, area
assert area["overrides"] == "measured.Measured", area
assert area["inherited"]["from"] == "measured.Measured", area
assert area["inherited"]["documentation"]["markdown"] == "The area, in square units.", area
PY
echo "PASS: haxeon doc describes a library's own public modules, without an entry, and a package can require its documentation"
