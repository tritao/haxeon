#!/usr/bin/env bash
# `internal` (docs/reference/LANGUAGE_SUPPORT.md): a package's internal types and members serve all of its own modules, and
# another package that names, constructs or reaches them gets E1031, as does a public declaration that exposes one; its API
# description marks them.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon=$root/scripts/haxeon
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-internal.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export HAXEON_COMPILER_SERVER=0

mkdir -p "$work/widgets/src/widgets/layout" "$work/app/src/app"
cat > "$work/widgets/haxeon.toml" <<'TOML'
version = 1
sourceRoots = ["src"]

[package]
name = "widgets"
TOML
# Shared by two modules in two Haxe packages of `widgets`: what `private` cannot do.
cat > "$work/widgets/src/widgets/layout/Measure.hx" <<'HAXE'
package widgets.layout;

internal class Measure {
	public static function width(text:String):Int {
		return text.length * 8;
	}
}

internal function padding():Int {
	return 4;
}
HAXE
cat > "$work/widgets/src/widgets/Label.hx" <<'HAXE'
package widgets;

import widgets.layout.Measure;

/** A line of text. */
class Label {
	public final text:String;

	/** The label's width before padding, for the package's other widgets. */
	internal var measured:Int;

	public function new(text:String) {
		this.text = text;
		measured = Measure.width(text);
	}

	public function width():Int {
		return measured + widgets.layout.Measure.padding() * 2;
	}

	internal function invalidate():Void {
		measured = Measure.width(text);
	}
}
HAXE
cat > "$work/widgets/src/widgets/Row.hx" <<'HAXE'
package widgets;

class Row {
	public final labels:Array<Label>;

	public function new(labels:Array<Label>) {
		this.labels = labels;
	}

	public function width():Int {
		// `internal` is a modifier only before a declaration: it stays usable as a name.
		var internal = 0;
		var total = internal;
		for (label in labels) {
			label.invalidate();
			total += label.measured;
		}
		return total;
	}
}
HAXE

cat > "$work/app/haxeon.toml" <<'TOML'
version = 1
entry = "app.Main"
sourceRoots = ["src"]

[package]
name = "app"

[dependencies]
widgets = { path = "../widgets" }
TOML
write_main() {
	cat > "$work/app/src/app/Main.hx" <<HAXE
package app;

import widgets.Label;
import widgets.Row;
$1

function main():Int {
	var row = new Row([new Label("ok"), new Label("go")]);
	$2
	return row.width() + new Label("ok").width() == 72 ? 42 : 1;
}
HAXE
}

cd "$work/app"
# Public API only: the package's internals work for it underneath.
write_main "" ""
"$haxeon" check

# Each way of reaching an internal declaration from another package.
expect_internal() {
	write_main "$1" "$2"
	if "$haxeon" check > "$work/out.txt" 2>&1; then
		echo "FAIL: $3 compiled" >&2
		exit 1
	fi
	if ! grep -q "E1031" "$work/out.txt" || ! grep -q "$4" "$work/out.txt"; then
		echo "FAIL: $3 did not report E1031 with \"$4\":" >&2
		cat "$work/out.txt" >&2
		exit 1
	fi
}
expect_internal "import widgets.layout.Measure;" "Measure.width(\"x\");" "an internal type's static" "Measure"
expect_internal "" "var width:widgets.layout.Measure = null;" "an internal type in an annotation" "Measure"
expect_internal "" "new Label(\"x\").invalidate();" "an internal method" "invalidate"
expect_internal "" "var measured = new Label(\"x\").measured;" "an internal field" "measured"
expect_internal "" "widgets.layout.Measure.padding();" "an internal module-level function" "padding"

# A declaration other packages see cannot expose an internal type: its users could not name what they hold.
cat > "$work/widgets/src/widgets/Leak.hx" <<'HAXE'
package widgets;

class Leak {
	public static function measure():widgets.layout.Measure {
		return null;
	}
}
HAXE
cd "$work/widgets"
# A library has no entry: `doc` analyzes it whole.
if "$haxeon" doc --output "$work/api.json" > "$work/out.txt" 2>&1 || ! grep -q "E1031" "$work/out.txt" \
	|| ! grep -q "widgets.Leak.measure is public but exposes widgets.layout.Measure" "$work/out.txt"; then
	echo "FAIL: a public method exposing an internal type was not E1031:" >&2
	cat "$work/out.txt" >&2
	exit 1
fi
# An internal or private member may name it.
sed -i 's/public static function measure/internal static function measure/' "$work/widgets/src/widgets/Leak.hx"

# The description of `widgets` leaves its internals out.
"$haxeon" doc --output "$work/api.json"
python3 - "$work/api.json" <<'PY'
import json
import sys

model = json.load(open(sys.argv[1]))
types = {entry["path"]: entry for entry in model["types"]}
assert types["widgets.layout.Measure"]["source"]["visibility"] == "internal", types["widgets.layout.Measure"]["source"]
label = {member["name"]: member for member in types["widgets.Label"]["members"]}
assert label["measured"]["source"]["visibility"] == "internal" and label["invalidate"]["source"]["visibility"] == "internal"
assert label["text"]["source"]["visibility"] == "public"
PY
echo "PASS: internal declarations serve their own package, are E1031 elsewhere, and are marked in its API description"
